use std::path::{Path, PathBuf};
use std::process::Output;

use sha2::{Digest as _, Sha256};

use super::bundle_contract::{
    GitBundleContentLimits, require_bounded_bundle, require_bounded_revision_tree,
    require_bounded_revision_tree_with_runner, require_self_contained_bundle,
};
use super::bundle_quarantine::GitBundleQuarantine;
use super::command::{GitCommandRunner, stdout};
use super::repository_coordinates::GitRepositoryCoordinates;
use super::source_repository_identity::{
    GitSourceRepositoryProof, exact_checkout_root, require_no_git_operation,
};
use crate::git::{GitError, GitRepository, GitResult};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitSourceBundleImportPlan {
    repository: PathBuf,
    repository_slug: String,
    revision: String,
    advertised_ref: String,
    import_ref: String,
    bundle_sha256: String,
    bundle_size: u64,
    repository_proof: GitSourceRepositoryProof,
    coordinates: GitRepositoryCoordinates,
}

impl GitSourceBundleImportPlan {
    pub(crate) fn new(
        repository: &Path,
        repository_slug: String,
        revision: String,
        advertised_ref: String,
        offer_request_sha256: &str,
        bundle_sha256: String,
        bundle_size: u64,
    ) -> GitResult<Self> {
        let repository = exact_checkout_root(repository)?;
        let coordinates = GitRepositoryCoordinates::freeze(&repository)?;
        let import_ref = format!(
            "refs/harness/task-board/source-imports/{offer_request_sha256}/{bundle_sha256}"
        );
        let plan = Self {
            repository,
            repository_slug,
            revision,
            advertised_ref,
            import_ref,
            bundle_sha256,
            bundle_size,
            repository_proof: GitSourceRepositoryProof::CanonicalOrigin,
            coordinates,
        };
        plan.validate_static_contract()?;
        Ok(plan)
    }

    pub(crate) fn verify_and_import_bytes(&self, bytes: &[u8]) -> GitResult<()> {
        self.verify_and_import_bytes_with_limits(bytes, GitBundleContentLimits::REMOTE_RESULT)
    }

    fn verify_and_import_bytes_with_limits(
        &self,
        bytes: &[u8],
        limits: GitBundleContentLimits,
    ) -> GitResult<()> {
        self.validate_static_contract()?;
        self.require_clean_repository()?;
        require_no_git_operation(&self.repository)?;
        self.require_initial_or_replay_ref()?;
        self.require_exact_bytes(bytes)?;
        require_bounded_bundle(&self.repository, bytes, limits)?;
        require_self_contained_bundle(&self.repository, bytes)?;
        let output_limit = u64::try_from(bytes.len()).map_err(|_| {
            GitError::unsafe_state(&self.repository, "source bundle length overflowed")
        })?;
        self.git_contract_bounded_with_input(["bundle", "verify", "-"], bytes, output_limit)?;
        self.require_exact_advertised_head(bytes, output_limit)?;
        let quarantine = GitBundleQuarantine::prepare(&self.coordinates, bytes, limits)?;
        let runner = quarantine.runner()?;
        self.require_commit_with_runner(&runner)?;
        require_bounded_revision_tree_with_runner(
            &self.repository,
            &runner,
            &self.revision,
            limits,
        )?;
        quarantine.promote(bytes)?;
        self.create_or_verify_import_ref()?;
        self.require_imported()
    }

    pub(crate) fn require_imported(&self) -> GitResult<()> {
        self.validate_static_contract()?;
        self.require_clean_repository()?;
        if self.optional_revision(&self.import_ref)?.as_deref() != Some(self.revision.as_str()) {
            return Err(GitError::unsafe_state(
                &self.repository,
                "source bundle import ref does not preserve the exact revision",
            ));
        }
        self.require_direct_ref(&self.import_ref)?;
        self.require_commit()?;
        require_bounded_revision_tree(
            &self.repository,
            &self.revision,
            GitBundleContentLimits::REMOTE_RESULT,
        )
    }

    pub(crate) fn cleanup_import_ref(&self) -> GitResult<()> {
        self.validate_static_contract()?;
        match self.optional_revision(&self.import_ref)? {
            None => Ok(()),
            Some(revision) if revision == self.revision => {
                self.require_direct_ref(&self.import_ref)?;
                self.git_mutation([
                    "update-ref",
                    "--no-deref",
                    "-d",
                    self.import_ref.as_str(),
                    self.revision.as_str(),
                ])?;
                Ok(())
            }
            Some(_) => Err(GitError::unsafe_state(
                &self.repository,
                "source bundle import ref changed before exact cleanup",
            )),
        }
    }

    fn validate_static_contract(&self) -> GitResult<()> {
        self.coordinates.require_dense_checkout()?;
        self.repository_proof
            .require(&self.repository, &self.repository_slug)?;
        let oid_len = match self.coordinates.object_format() {
            "sha1" => 40,
            "sha256" => 64,
            _ => {
                return Err(GitError::unsafe_state(
                    &self.repository,
                    "source bundle import uses an unsupported object format",
                ));
            }
        };
        let exact_ref = format!("refs/harness/task-board/sources/{}", self.revision);
        let exact = canonical_oid(&self.revision, oid_len)
            && canonical_digest(&self.bundle_sha256)
            && self.bundle_size > 0
            && self.bundle_size <= GitBundleContentLimits::REMOTE_RESULT.max_bundle_bytes
            && self.advertised_ref == exact_ref
            && canonical_import_ref(&self.import_ref, &self.bundle_sha256);
        if !exact {
            return Err(GitError::unsafe_state(
                &self.repository,
                "source bundle import identity is noncanonical",
            ));
        }
        for reference in [self.advertised_ref.as_str(), self.import_ref.as_str()] {
            self.git_contract(["check-ref-format", reference])?;
        }
        Ok(())
    }

    fn require_clean_repository(&self) -> GitResult<()> {
        if GitRepository::from_path(&self.repository).has_changes_including_untracked()? {
            Err(GitError::unsafe_state(
                &self.repository,
                "source bundle import requires a clean configured checkout",
            ))
        } else {
            Ok(())
        }
    }

    fn require_initial_or_replay_ref(&self) -> GitResult<()> {
        if let Some(revision) = self.optional_revision(&self.import_ref)? {
            self.require_direct_ref(&self.import_ref)?;
            if revision != self.revision {
                return Err(GitError::unsafe_state(
                    &self.repository,
                    "source bundle import ref conflicts with another revision",
                ));
            }
        }
        Ok(())
    }

    fn require_exact_bytes(&self, bytes: &[u8]) -> GitResult<()> {
        let size = u64::try_from(bytes.len()).map_err(|_| {
            GitError::unsafe_state(&self.repository, "source bundle length overflowed")
        })?;
        if size == self.bundle_size && hex::encode(Sha256::digest(bytes)) == self.bundle_sha256 {
            Ok(())
        } else {
            Err(GitError::unsafe_state(
                &self.repository,
                "source bundle bytes do not match their sealed digest and size",
            ))
        }
    }

    fn require_exact_advertised_head(&self, bytes: &[u8], output_limit: u64) -> GitResult<()> {
        let output = self.git_contract_bounded_with_input(
            ["bundle", "list-heads", "-"],
            bytes,
            output_limit,
        )?;
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
            Err(GitError::unsafe_state(
                &self.repository,
                "source bundle advertised an unexpected revision",
            ))
        }
    }

    fn require_commit(&self) -> GitResult<()> {
        let runner = self.coordinates.runner()?;
        self.require_commit_with_runner(&runner)
    }

    fn require_commit_with_runner(&self, runner: &GitCommandRunner<'_>) -> GitResult<()> {
        if stdout(&runner.contract(["cat-file", "-t", self.revision.as_str()])?) == "commit"
            && stdout(&runner.contract(["rev-parse", "--verify", self.revision.as_str()])?)
                == self.revision
        {
            Ok(())
        } else {
            Err(GitError::unsafe_state(
                &self.repository,
                "source bundle revision is not an exact commit",
            ))
        }
    }

    fn create_or_verify_import_ref(&self) -> GitResult<()> {
        if self.optional_revision(&self.import_ref)?.is_some() {
            return self.require_initial_or_replay_ref();
        }
        let zero = "0".repeat(self.revision.len());
        self.git_mutation([
            "update-ref",
            "--no-deref",
            self.import_ref.as_str(),
            self.revision.as_str(),
            zero.as_str(),
        ])?;
        self.require_initial_or_replay_ref()
    }

    fn require_direct_ref(&self, reference: &str) -> GitResult<()> {
        if self
            .git_probe(["symbolic-ref", "--quiet", reference])?
            .status
            .success()
        {
            Err(GitError::unsafe_state(
                &self.repository,
                "source bundle import refuses a symbolic private ref",
            ))
        } else {
            Ok(())
        }
    }

    fn optional_revision(&self, reference: &str) -> GitResult<Option<String>> {
        let output = self.git_probe(["rev-parse", "--verify", "--quiet", reference])?;
        Ok(output.status.success().then(|| stdout(&output)))
    }

    fn git_contract<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.coordinates.runner()?.contract(args)
    }

    fn git_probe<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.coordinates.runner()?.probe(args)
    }

    fn git_mutation<const N: usize>(&self, args: [&str; N]) -> GitResult<Output> {
        self.coordinates.runner()?.mutation(args)
    }

    fn git_contract_bounded_with_input<const N: usize>(
        &self,
        args: [&str; N],
        bytes: &[u8],
        max_bytes: u64,
    ) -> GitResult<Output> {
        self.coordinates
            .runner()?
            .contract_bounded_with_input(args, bytes, max_bytes)
    }
}

fn canonical_oid(value: &str, expected_len: usize) -> bool {
    value.len() == expected_len
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn canonical_digest(value: &str) -> bool {
    canonical_oid(value, 64)
}

fn canonical_import_ref(reference: &str, bundle_sha256: &str) -> bool {
    let Some(suffix) = reference.strip_prefix("refs/harness/task-board/source-imports/") else {
        return false;
    };
    let mut segments = suffix.split('/');
    let request_sha256 = segments.next().unwrap_or_default();
    let bundle = segments.next().unwrap_or_default();
    segments.next().is_none() && canonical_digest(request_sha256) && bundle == bundle_sha256
}

#[cfg(test)]
#[path = "source_bundle_import/tests.rs"]
mod tests;
