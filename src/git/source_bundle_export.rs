use std::path::{Path, PathBuf};
use std::process::Output;

use super::bundle_contract::{
    GitBundleContentLimits, require_bounded_bundle, require_bounded_revision_tree,
    require_self_contained_bundle,
};
use super::command::stdout;
use super::repository_coordinates::GitRepositoryCoordinates;
use super::source_repository_identity::{
    GitSourceRepositoryProof, exact_checkout_root, require_no_git_operation,
};
use crate::git::{GitError, GitRepository, GitResult};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitSourceBundleExport {
    pub(crate) repository: String,
    pub(crate) revision: String,
    pub(crate) advertised_ref: String,
    pub(crate) bytes: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitSourceBundleExportPlan {
    worktree: PathBuf,
    repository: String,
    revision: String,
    advertised_ref: String,
    repository_proof: GitSourceRepositoryProof,
    coordinates: GitRepositoryCoordinates,
}

impl GitSourceBundleExportPlan {
    pub(crate) fn for_revision(
        worktree: &Path,
        repository: String,
        revision: String,
    ) -> GitResult<Self> {
        Self::new(
            worktree,
            repository,
            revision,
            GitSourceRepositoryProof::CanonicalOrigin,
        )
    }

    pub(crate) fn for_configured_revision(
        worktree: &Path,
        configured_checkout: &Path,
        repository: String,
        revision: String,
    ) -> GitResult<Self> {
        let proof = GitSourceRepositoryProof::configured(configured_checkout)?;
        Self::new(worktree, repository, revision, proof)
    }

    fn new(
        worktree: &Path,
        repository: String,
        revision: String,
        repository_proof: GitSourceRepositoryProof,
    ) -> GitResult<Self> {
        let canonical = exact_checkout_root(worktree)?;
        let coordinates = GitRepositoryCoordinates::freeze(&canonical)?;
        let advertised_ref = format!("refs/harness/task-board/sources/{revision}");
        let plan = Self {
            worktree: canonical,
            repository,
            revision,
            advertised_ref,
            repository_proof,
            coordinates,
        };
        plan.validate()?;
        Ok(plan)
    }

    pub(crate) fn export(&self, max_bytes: u64) -> GitResult<GitSourceBundleExport> {
        if max_bytes == 0 {
            return Err(GitError::read(
                &self.worktree,
                "source bundle export byte limit is zero",
            ));
        }
        self.validate()?;
        self.create_or_verify_source_ref()?;
        let result = self.export_with_ref(max_bytes);
        let cleanup = self.cleanup_source_ref();
        match (result, cleanup) {
            (Ok(bundle), Ok(())) => Ok(bundle),
            (Err(error), _) | (Ok(_), Err(error)) => Err(error),
        }
    }

    fn validate(&self) -> GitResult<()> {
        self.coordinates.require_dense_checkout()?;
        let object_format = self.coordinates.object_format();
        let oid_len = match object_format {
            "sha1" => 40,
            "sha256" => 64,
            _ => {
                return Err(GitError::read(
                    &self.worktree,
                    "source bundle repository uses an unsupported object format",
                ));
            }
        };
        let repository = GitRepository::discover(&self.worktree)?;
        self.repository_proof
            .require(&self.worktree, &self.repository)?;
        require_no_git_operation(&self.worktree)?;
        if repository.path() != self.worktree
            || repository.has_changes_including_untracked()?
            || !canonical_oid(&self.revision, oid_len)
            || self.revision("HEAD")? != self.revision
        {
            return Err(GitError::read(
                &self.worktree,
                "source bundle export is not the clean exact repository revision",
            ));
        }
        self.require_commit()?;
        require_bounded_revision_tree(
            &self.worktree,
            &self.revision,
            GitBundleContentLimits::REMOTE_RESULT,
        )?;
        self.git_read(["check-ref-format", self.advertised_ref.as_str()])?;
        Ok(())
    }

    fn export_with_ref(&self, max_bytes: u64) -> GitResult<GitSourceBundleExport> {
        let limits = GitBundleContentLimits {
            max_bundle_bytes: max_bytes.min(GitBundleContentLimits::REMOTE_RESULT.max_bundle_bytes),
            ..GitBundleContentLimits::REMOTE_RESULT
        };
        let output = self.git_mutation_bounded_stdout(
            [
                "bundle",
                "create",
                "--version=2",
                "-",
                self.advertised_ref.as_str(),
            ],
            limits.max_bundle_bytes,
        )?;
        let bytes = output.stdout;
        require_bounded_bundle(&self.worktree, &bytes, limits)?;
        require_self_contained_bundle(&self.worktree, &bytes)?;
        self.git_contract_bounded_with_input(
            ["bundle", "verify", "-"],
            &bytes,
            limits.max_bundle_bytes,
        )?;
        self.require_exact_head(&bytes)?;
        Ok(GitSourceBundleExport {
            repository: self.repository.clone(),
            revision: self.revision.clone(),
            advertised_ref: self.advertised_ref.clone(),
            bytes,
        })
    }

    fn create_or_verify_source_ref(&self) -> GitResult<()> {
        if let Some(current) = self.optional_revision(&self.advertised_ref)? {
            self.require_direct_ref()?;
            return if current == self.revision {
                Ok(())
            } else {
                Err(GitError::mutation(
                    &self.worktree,
                    "source bundle ref conflicts with another revision",
                ))
            };
        }
        let zero = "0".repeat(self.revision.len());
        self.git_mutation([
            "update-ref",
            "--no-deref",
            self.advertised_ref.as_str(),
            self.revision.as_str(),
            zero.as_str(),
        ])?;
        self.require_direct_ref()
    }

    fn cleanup_source_ref(&self) -> GitResult<()> {
        match self.optional_revision(&self.advertised_ref)? {
            None => Ok(()),
            Some(current) if current == self.revision => {
                self.require_direct_ref()?;
                self.git_mutation([
                    "update-ref",
                    "--no-deref",
                    "-d",
                    self.advertised_ref.as_str(),
                    self.revision.as_str(),
                ])?;
                Ok(())
            }
            Some(_) => Err(GitError::mutation(
                &self.worktree,
                "source bundle ref changed before exact cleanup",
            )),
        }
    }

    fn require_exact_head(&self, bytes: &[u8]) -> GitResult<()> {
        let max_output = u64::try_from(bytes.len()).map_err(|_| {
            GitError::unsafe_state(&self.worktree, "source bundle length overflowed")
        })?;
        let output =
            self.git_contract_bounded_with_input(["bundle", "list-heads", "-"], bytes, max_output)?;
        let heads = stdout(&output);
        let lines = heads
            .lines()
            .filter(|line| !line.is_empty())
            .collect::<Vec<_>>();
        let exact = lines.first().and_then(|line| line.split_once(' '));
        if lines.len() == 1 && exact == Some((self.revision.as_str(), self.advertised_ref.as_str()))
        {
            Ok(())
        } else {
            Err(GitError::read(
                &self.worktree,
                "source bundle advertised an unexpected revision",
            ))
        }
    }

    fn require_commit(&self) -> GitResult<()> {
        if stdout(&self.git_read(["cat-file", "-t", self.revision.as_str()])?) == "commit"
            && self.revision(&self.revision)? == self.revision
        {
            Ok(())
        } else {
            Err(GitError::read(
                &self.worktree,
                "source bundle revision is not an exact commit",
            ))
        }
    }

    fn require_direct_ref(&self) -> GitResult<()> {
        let output = self.git_probe(["symbolic-ref", "--quiet", self.advertised_ref.as_str()])?;
        if output.status.success() {
            Err(GitError::unsafe_state(
                &self.worktree,
                "source bundle export refuses a symbolic private ref",
            ))
        } else {
            Ok(())
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

fn canonical_oid(value: &str, expected_len: usize) -> bool {
    value.len() == expected_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

#[cfg(test)]
#[path = "source_bundle_export/tests.rs"]
mod tests;
