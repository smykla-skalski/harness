use std::path::{Path, PathBuf};
use std::process::Output;

use super::bundle_contract::{
    GitBundleContentLimits, require_bounded_bundle, require_bounded_result_delta_with_runner,
};
use super::bundle_staging::GitBundleStaging;
use super::command::stdout;
use super::repository_coordinates::GitRepositoryCoordinates;
use crate::git::{GitError, GitResult};

const MAX_STATUS_OUTPUT_BYTES: u64 = 64 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitBundleExport {
    pub(crate) base_revision: String,
    pub(crate) result_revision: String,
    pub(crate) advertised_ref: String,
    pub(crate) bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitBundleExportPlan {
    worktree: PathBuf,
    base_revision: String,
    result_revision: String,
    advertised_ref: String,
    coordinates: GitRepositoryCoordinates,
}

impl GitBundleExportPlan {
    pub(crate) fn for_result(
        worktree: &Path,
        base_revision: String,
        result_revision: String,
    ) -> GitResult<Self> {
        let coordinates = GitRepositoryCoordinates::freeze(worktree)?;
        let canonical = coordinates.worktree().to_path_buf();
        let advertised_ref = format!("refs/harness/task-board/results/{result_revision}");
        let plan = Self {
            worktree: canonical,
            base_revision,
            result_revision,
            advertised_ref,
            coordinates,
        };
        plan.validate()?;
        Ok(plan)
    }

    pub(crate) fn export(&self, max_bytes: u64) -> GitResult<GitBundleExport> {
        if max_bytes == 0 {
            return Err(GitError::read(
                &self.worktree,
                "bundle export byte limit is zero",
            ));
        }
        self.validate()?;
        self.create_or_verify_result_ref()?;
        let result = self.export_with_ref(max_bytes);
        let cleanup = self.cleanup_result_ref();
        match (result, cleanup) {
            (Ok(bundle), Ok(())) => Ok(bundle),
            (Err(error), _) | (Ok(_), Err(error)) => Err(error),
        }
    }

    fn validate(&self) -> GitResult<()> {
        self.coordinates.require_current()?;
        self.coordinates.require_dense_checkout()?;
        self.require_no_git_operation()?;
        if self.has_changes_including_untracked()?
            || self.revision("HEAD")? != self.result_revision
            || self.base_revision == self.result_revision
        {
            return Err(GitError::read(
                &self.worktree,
                "bundle export worktree is not the clean exact result",
            ));
        }
        self.require_commit(&self.base_revision, "bundle base")?;
        self.require_commit(&self.result_revision, "bundle result")?;
        self.require_ancestry()?;
        let runner = self.coordinates.runner()?;
        require_bounded_result_delta_with_runner(
            &self.worktree,
            &runner,
            &self.base_revision,
            &self.result_revision,
            GitBundleContentLimits::REMOTE_RESULT,
        )?;
        self.git_read(["check-ref-format", self.advertised_ref.as_str()])?;
        Ok(())
    }

    fn export_with_ref(&self, max_bytes: u64) -> GitResult<GitBundleExport> {
        let limits = GitBundleContentLimits {
            max_bundle_bytes: max_bytes.min(GitBundleContentLimits::REMOTE_RESULT.max_bundle_bytes),
            ..GitBundleContentLimits::REMOTE_RESULT
        };
        let excluded = format!("^{}", self.base_revision);
        let output = self.git_mutation_bounded_stdout(
            [
                "bundle",
                "create",
                "--version=2",
                "-",
                self.advertised_ref.as_str(),
                excluded.as_str(),
            ],
            limits.max_bundle_bytes,
        )?;
        let bytes = output.stdout;
        require_bounded_bundle(&self.worktree, &bytes, limits)?;
        {
            let staged =
                GitBundleStaging::prepare(&self.coordinates, &bytes, limits.max_bundle_bytes)?;
            let staged_path = staged.path()?;
            self.git_contract_bounded_with_input(
                ["bundle", "verify", staged_path],
                &[],
                limits.max_bundle_bytes,
            )?;
        }
        self.require_exact_head(&bytes)?;
        Ok(GitBundleExport {
            base_revision: self.base_revision.clone(),
            result_revision: self.result_revision.clone(),
            advertised_ref: self.advertised_ref.clone(),
            bytes,
        })
    }

    fn create_or_verify_result_ref(&self) -> GitResult<()> {
        if let Some(current) = self.optional_revision(&self.advertised_ref)? {
            self.require_direct_ref(&self.advertised_ref)?;
            return if current == self.result_revision {
                Ok(())
            } else {
                Err(GitError::mutation(
                    &self.worktree,
                    "bundle export ref conflicts with another result",
                ))
            };
        }
        let zero = "0".repeat(self.result_revision.len());
        self.git_mutation([
            "update-ref",
            "--no-deref",
            self.advertised_ref.as_str(),
            self.result_revision.as_str(),
            zero.as_str(),
        ])?;
        self.require_direct_ref(&self.advertised_ref)
    }

    fn cleanup_result_ref(&self) -> GitResult<()> {
        match self.optional_revision(&self.advertised_ref)? {
            None => Ok(()),
            Some(current) if current == self.result_revision => {
                self.require_direct_ref(&self.advertised_ref)?;
                self.git_mutation([
                    "update-ref",
                    "--no-deref",
                    "-d",
                    self.advertised_ref.as_str(),
                    self.result_revision.as_str(),
                ])?;
                Ok(())
            }
            Some(_) => Err(GitError::mutation(
                &self.worktree,
                "bundle export ref changed before exact cleanup",
            )),
        }
    }

    fn require_exact_head(&self, bytes: &[u8]) -> GitResult<()> {
        let max_output = u64::try_from(bytes.len())
            .map_err(|_| GitError::unsafe_state(&self.worktree, "git bundle length overflowed"))?;
        let output =
            self.git_contract_bounded_with_input(["bundle", "list-heads", "-"], bytes, max_output)?;
        let heads = stdout(&output);
        let lines = heads
            .lines()
            .filter(|line| !line.is_empty())
            .collect::<Vec<_>>();
        let exact = lines.first().and_then(|line| line.split_once(' '));
        if lines.len() == 1
            && exact == Some((self.result_revision.as_str(), self.advertised_ref.as_str()))
        {
            Ok(())
        } else {
            Err(GitError::read(
                &self.worktree,
                "bundle export advertised an unexpected result",
            ))
        }
    }

    fn require_commit(&self, revision: &str, label: &str) -> GitResult<()> {
        if stdout(&self.git_read(["cat-file", "-t", revision])?) == "commit"
            && self.revision(revision)? == revision
        {
            Ok(())
        } else {
            Err(GitError::read(
                &self.worktree,
                format!("{label} is not an exact commit object"),
            ))
        }
    }

    fn require_ancestry(&self) -> GitResult<()> {
        let output = self.git_probe([
            "merge-base",
            "--is-ancestor",
            self.base_revision.as_str(),
            self.result_revision.as_str(),
        ])?;
        if output.status.success() {
            Ok(())
        } else {
            Err(GitError::read(
                &self.worktree,
                "bundle result does not descend from its frozen base",
            ))
        }
    }

    fn revision(&self, revision: &str) -> GitResult<String> {
        Ok(stdout(&self.git_read([
            "rev-parse",
            "--verify",
            revision,
        ])?))
    }

    fn optional_revision(&self, revision: &str) -> GitResult<Option<String>> {
        let output = self.git_probe(["rev-parse", "--verify", "--quiet", revision])?;
        Ok(output.status.success().then(|| stdout(&output)))
    }

    fn require_direct_ref(&self, reference: &str) -> GitResult<()> {
        let output = self.git_probe(["symbolic-ref", "--quiet", reference])?;
        if output.status.success() {
            Err(GitError::unsafe_state(
                &self.worktree,
                format!("bundle export refuses symbolic ref {reference}"),
            ))
        } else {
            Ok(())
        }
    }

    fn has_changes_including_untracked(&self) -> GitResult<bool> {
        let output = self.coordinates.runner()?.read_bounded_stdout(
            ["status", "--porcelain=v1", "--untracked-files=all"],
            MAX_STATUS_OUTPUT_BYTES,
        )?;
        Ok(!output.stdout.is_empty())
    }

    fn require_no_git_operation(&self) -> GitResult<()> {
        for marker in [
            "MERGE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "BISECT_LOG",
            "rebase-apply",
            "rebase-merge",
            "sequencer",
        ] {
            let marker_path = stdout(&self.git_read([
                "rev-parse",
                "--path-format=absolute",
                "--git-path",
                marker,
            ])?);
            if Path::new(&marker_path).exists() {
                return Err(GitError::unsafe_state(
                    &self.worktree,
                    "bundle export refuses an in-progress git operation",
                ));
            }
        }
        Ok(())
    }

    fn git_read<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.coordinates.runner()?.read(args)
    }

    fn git_mutation<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.coordinates.runner()?.mutation(args)
    }

    fn git_mutation_bounded_stdout<const N: usize>(
        &self,
        args: [&str; N],
        max_bytes: u64,
    ) -> GitResult<Output> {
        self.coordinates
            .runner()?
            .mutation_bounded_stdout(args, max_bytes)
    }

    fn git_contract_bounded_with_input<const N: usize>(
        &self,
        args: [&str; N],
        input: &[u8],
        max_bytes: u64,
    ) -> GitResult<Output> {
        self.coordinates
            .runner()?
            .contract_bounded_with_input(args, input, max_bytes)
    }

    fn git_probe<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.coordinates.runner()?.probe(args)
    }
}

#[cfg(test)]
#[path = "bundle_export/tests.rs"]
mod tests;
