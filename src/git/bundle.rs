use std::fs;
use std::path::{Path, PathBuf};

use super::bundle_contract::{
    GitBundleContentLimits, read_bounded_bundle_file, require_bounded_bundle,
    require_bounded_result_delta_with_runner,
};
use super::bundle_quarantine::GitBundleQuarantine;
use super::command::stdout;
use super::repository_coordinates::GitRepositoryCoordinates;
use crate::git::{GitError, GitRepository, GitResult};

#[path = "bundle/operations.rs"]
mod operations;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitBundleImportPlan {
    worktree: PathBuf,
    branch_ref: String,
    base_revision: String,
    result_revision: String,
    advertised_ref: String,
    import_ref: String,
    coordinates: GitRepositoryCoordinates,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitBundleImportEvidence {
    pub(crate) worktree_path: String,
    pub(crate) git_dir: String,
    pub(crate) common_git_dir: String,
    pub(crate) branch_ref: String,
    pub(crate) base_revision: String,
    pub(crate) result_revision: String,
    pub(crate) advertised_ref: String,
    pub(crate) import_ref: String,
    pub(crate) object_format: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum GitBundleWorktreeState {
    AttachedBase,
    DetachedResultBranchBase,
    DetachedResultBranchResult,
    AttachedResult,
}

impl GitBundleImportPlan {
    pub(crate) fn new(
        worktree: &Path,
        branch_ref: String,
        base_revision: String,
        result_revision: String,
        advertised_ref: String,
        import_ref: String,
    ) -> GitResult<Self> {
        let coordinates = GitRepositoryCoordinates::freeze(worktree)?;
        let canonical = coordinates.worktree().to_path_buf();
        if !branch_ref.starts_with("refs/heads/") {
            return Err(GitError::unsafe_state(
                worktree,
                "bundle import must target the exact frozen worktree branch",
            ));
        }
        let plan = Self {
            worktree: canonical,
            branch_ref,
            base_revision,
            result_revision,
            advertised_ref,
            import_ref,
            coordinates,
        };
        plan.validate_static_contract()?;
        Ok(plan)
    }

    pub(crate) fn evidence(&self) -> GitResult<GitBundleImportEvidence> {
        self.coordinates.require_current()?;
        Ok(GitBundleImportEvidence {
            worktree_path: self.worktree.to_string_lossy().into_owned(),
            git_dir: self.coordinates.git_dir().to_string_lossy().into_owned(),
            common_git_dir: self
                .coordinates
                .common_git_dir()
                .to_string_lossy()
                .into_owned(),
            branch_ref: self.branch_ref.clone(),
            base_revision: self.base_revision.clone(),
            result_revision: self.result_revision.clone(),
            advertised_ref: self.advertised_ref.clone(),
            import_ref: self.import_ref.clone(),
            object_format: self.coordinates.object_format().to_owned(),
        })
    }

    pub(crate) fn verify_and_import_objects(&self, bundle: &Path) -> GitResult<()> {
        self.verify_and_import_objects_with_limits(bundle, GitBundleContentLimits::REMOTE_RESULT)
    }

    pub(crate) fn verify_and_import_bytes(&self, bytes: &[u8]) -> GitResult<()> {
        self.verify_and_import_bytes_with_limits(
            &self.worktree,
            bytes,
            GitBundleContentLimits::REMOTE_RESULT,
        )
    }

    fn verify_and_import_objects_with_limits(
        &self,
        bundle: &Path,
        limits: GitBundleContentLimits,
    ) -> GitResult<()> {
        let bytes = read_bounded_bundle_file(bundle, limits.max_bundle_bytes)?;
        self.verify_and_import_bytes_with_limits(bundle, &bytes, limits)
    }

    fn verify_and_import_bytes_with_limits(
        &self,
        bundle: &Path,
        bytes: &[u8],
        limits: GitBundleContentLimits,
    ) -> GitResult<()> {
        self.require_initial_or_replay_state()?;
        require_bounded_bundle(bundle, bytes, limits)?;
        let output_limit = u64::try_from(bytes.len())
            .map_err(|_| GitError::unsafe_state(bundle, "git bundle length overflowed"))?;
        // git bundle verify cannot check prerequisite reachability when the bundle
        // is read from stdin (recent git closes rev-list's pipe early), so stage the
        // bytes in the private git dir and verify the file; the quarantine that
        // follows writes the same bytes anyway.
        let staged = tempfile::NamedTempFile::new_in(self.coordinates.common_git_dir())
            .map_err(|error| GitError::unsafe_state(bundle, format!("stage bundle: {error}")))?;
        fs::write(staged.path(), bytes)
            .map_err(|error| GitError::unsafe_state(bundle, format!("stage bundle: {error}")))?;
        let staged_path = staged
            .path()
            .to_str()
            .ok_or_else(|| GitError::unsafe_state(bundle, "staged bundle path is not UTF-8"))?;
        self.git_contract_bounded_with_input(["bundle", "verify", staged_path], &[], output_limit)?;
        drop(staged);
        self.require_exact_advertised_head(bundle, bytes)?;
        let quarantine = GitBundleQuarantine::prepare(&self.coordinates, bytes, limits)?;
        let runner = quarantine.runner()?;
        self.require_commit_with_runner(&runner, &self.base_revision, "bundle base")?;
        self.require_commit_with_runner(&runner, &self.result_revision, "bundle result")?;
        self.require_ancestry_with_runner(&runner)?;
        require_bounded_result_delta_with_runner(
            &self.worktree,
            &runner,
            &self.base_revision,
            &self.result_revision,
            limits,
        )?;
        quarantine.promote(bytes)?;
        self.create_or_verify_import_ref()
    }

    pub(crate) fn state(&self) -> GitResult<GitBundleWorktreeState> {
        self.coordinates.require_dense_checkout()?;
        self.require_no_git_operation()?;
        if GitRepository::from_path(&self.worktree).has_changes_including_untracked()? {
            return Err(GitError::unsafe_state(
                &self.worktree,
                "bundle import worktree contains tracked, index, or untracked changes",
            ));
        }
        self.require_direct_ref(&self.branch_ref)?;
        let head = self.revision("HEAD")?;
        let branch = self.revision(&self.branch_ref)?;
        match (self.symbolic_head()?, head.as_str(), branch.as_str()) {
            (Some(reference), head, branch)
                if reference == self.branch_ref
                    && head == self.base_revision
                    && branch == self.base_revision =>
            {
                Ok(GitBundleWorktreeState::AttachedBase)
            }
            (None, head, branch)
                if head == self.result_revision && branch == self.base_revision =>
            {
                Ok(GitBundleWorktreeState::DetachedResultBranchBase)
            }
            (None, head, branch)
                if head == self.result_revision && branch == self.result_revision =>
            {
                Ok(GitBundleWorktreeState::DetachedResultBranchResult)
            }
            (Some(reference), head, branch)
                if reference == self.branch_ref
                    && head == self.result_revision
                    && branch == self.result_revision =>
            {
                Ok(GitBundleWorktreeState::AttachedResult)
            }
            _ => Err(GitError::unsafe_state(
                &self.worktree,
                "bundle import worktree is not at a replay-safe state",
            )),
        }
    }

    pub(crate) fn advance_one(&self) -> GitResult<GitBundleWorktreeState> {
        self.require_import_ref()?;
        match self.state()? {
            GitBundleWorktreeState::AttachedBase => {
                self.git_mutation([
                    "checkout",
                    "--detach",
                    "--no-recurse-submodules",
                    self.result_revision.as_str(),
                ])?;
            }
            GitBundleWorktreeState::DetachedResultBranchBase => {
                self.git_mutation([
                    "update-ref",
                    "--no-deref",
                    self.branch_ref.as_str(),
                    self.result_revision.as_str(),
                    self.base_revision.as_str(),
                ])?;
            }
            GitBundleWorktreeState::DetachedResultBranchResult => {
                self.attach_result_branch()?;
            }
            GitBundleWorktreeState::AttachedResult => {}
        }
        self.state()
    }

    pub(crate) fn require_applied(&self) -> GitResult<GitBundleImportEvidence> {
        if self.state()? != GitBundleWorktreeState::AttachedResult {
            return Err(GitError::unsafe_state(
                &self.worktree,
                "bundle import has not reached its exact attached result",
            ));
        }
        self.require_import_ref()?;
        self.require_ancestry()?;
        self.evidence()
    }

    pub(crate) fn cleanup_import_ref(&self) -> GitResult<()> {
        match self.optional_revision(&self.import_ref)? {
            None => Ok(()),
            Some(revision) if revision == self.result_revision => {
                self.require_direct_ref(&self.import_ref)?;
                self.git_mutation([
                    "update-ref",
                    "--no-deref",
                    "-d",
                    self.import_ref.as_str(),
                    self.result_revision.as_str(),
                ])?;
                Ok(())
            }
            Some(_) => Err(GitError::unsafe_state(
                &self.worktree,
                "bundle import ref changed before exact cleanup",
            )),
        }
    }

    fn validate_static_contract(&self) -> GitResult<()> {
        if self.base_revision == self.result_revision {
            return Err(GitError::unsafe_state(
                &self.worktree,
                "bundle result must differ from its frozen base",
            ));
        }
        self.coordinates.require_dense_checkout()?;
        let object_format = self.coordinates.object_format();
        let oid_len = match object_format {
            "sha1" => 40,
            "sha256" => 64,
            _ => {
                return Err(GitError::unsafe_state(
                    &self.worktree,
                    "bundle import repository uses an unsupported object format",
                ));
            }
        };
        if !canonical_oid(&self.base_revision, oid_len)
            || !canonical_oid(&self.result_revision, oid_len)
            || !self
                .advertised_ref
                .starts_with("refs/harness/task-board/results/")
            || !canonical_import_ref(&self.import_ref)
        {
            return Err(GitError::unsafe_state(
                &self.worktree,
                "bundle import revisions or private refs are noncanonical",
            ));
        }
        for reference in [
            self.branch_ref.as_str(),
            self.advertised_ref.as_str(),
            self.import_ref.as_str(),
        ] {
            self.git_contract(["check-ref-format", reference])?;
        }
        self.require_commit(&self.base_revision, "bundle base")
    }

    fn require_initial_or_replay_state(&self) -> GitResult<()> {
        match self.state()? {
            GitBundleWorktreeState::AttachedBase
            | GitBundleWorktreeState::DetachedResultBranchBase
            | GitBundleWorktreeState::DetachedResultBranchResult
            | GitBundleWorktreeState::AttachedResult => Ok(()),
        }
    }

    fn require_exact_advertised_head(&self, bundle: &Path, bytes: &[u8]) -> GitResult<()> {
        let max_output = u64::try_from(bytes.len())
            .map_err(|_| GitError::unsafe_state(bundle, "git bundle length overflowed"))?;
        let output =
            self.git_contract_bounded_with_input(["bundle", "list-heads", "-"], bytes, max_output)?;
        let listed_heads = stdout(&output);
        let lines = listed_heads
            .lines()
            .filter(|line| !line.trim().is_empty())
            .collect::<Vec<_>>();
        let exact = lines
            .as_slice()
            .first()
            .and_then(|line| line.split_once(' '));
        if lines.len() == 1
            && exact == Some((self.result_revision.as_str(), self.advertised_ref.as_str()))
        {
            Ok(())
        } else {
            Err(GitError::unsafe_state(
                bundle,
                "git bundle does not advertise the exact sealed result ref",
            ))
        }
    }

    fn require_commit(&self, revision: &str, label: &str) -> GitResult<()> {
        let runner = self.coordinates.runner()?;
        self.require_commit_with_runner(&runner, revision, label)
    }

    fn require_commit_with_runner(
        &self,
        runner: &super::command::GitCommandRunner<'_>,
        revision: &str,
        label: &str,
    ) -> GitResult<()> {
        let object_type = stdout(&runner.contract(["cat-file", "-t", revision])?);
        let exact = stdout(&runner.contract(["rev-parse", "--verify", revision])?);
        if object_type.trim() != "commit" || exact != revision {
            return Err(GitError::unsafe_state(
                &self.worktree,
                format!("{label} is not an exact commit object"),
            ));
        }
        Ok(())
    }

    fn require_ancestry(&self) -> GitResult<()> {
        let runner = self.coordinates.runner()?;
        self.require_ancestry_with_runner(&runner)
    }

    fn require_ancestry_with_runner(
        &self,
        runner: &super::command::GitCommandRunner<'_>,
    ) -> GitResult<()> {
        let output = runner.probe([
            "merge-base",
            "--is-ancestor",
            self.base_revision.as_str(),
            self.result_revision.as_str(),
        ])?;
        if output.status.success() {
            Ok(())
        } else {
            Err(GitError::unsafe_state(
                &self.worktree,
                "bundle result does not descend from the exact frozen base",
            ))
        }
    }

    fn create_or_verify_import_ref(&self) -> GitResult<()> {
        if let Some(current) = self.optional_revision(&self.import_ref)? {
            self.require_direct_ref(&self.import_ref)?;
            return if current == self.result_revision {
                Ok(())
            } else {
                Err(GitError::unsafe_state(
                    &self.worktree,
                    "bundle import ref conflicts with another result",
                ))
            };
        }
        let zero = "0".repeat(self.result_revision.len());
        self.git_mutation([
            "update-ref",
            "--no-deref",
            self.import_ref.as_str(),
            self.result_revision.as_str(),
            zero.as_str(),
        ])?;
        self.require_import_ref()
    }

    fn require_import_ref(&self) -> GitResult<()> {
        let current = self.optional_revision(&self.import_ref)?;
        if current.as_deref() == Some(self.result_revision.as_str()) {
            self.require_direct_ref(&self.import_ref)
        } else {
            Err(GitError::unsafe_state(
                &self.worktree,
                "bundle import ref does not preserve the exact result object",
            ))
        }
    }
}

fn canonical_oid(value: &str, expected_len: usize) -> bool {
    value.len() == expected_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn canonical_import_ref(reference: &str) -> bool {
    let Some(suffix) = reference.strip_prefix("refs/harness/task-board/imports/") else {
        return false;
    };
    let mut segments = suffix.split('/');
    let offer_sha256 = segments.next().unwrap_or_default();
    let bundle_sha256 = segments.next().unwrap_or_default();
    segments.next().is_none() && canonical_oid(offer_sha256, 64) && canonical_oid(bundle_sha256, 64)
}

#[cfg(test)]
#[path = "bundle/tests.rs"]
mod tests;
