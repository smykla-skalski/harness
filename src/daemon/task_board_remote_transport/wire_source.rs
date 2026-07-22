use serde::{Deserialize, Serialize};

use super::wire::{
    RemoteArtifactEntry, RemoteArtifactManifest, RemoteAttemptBinding, RemoteWireError,
    require_max_bytes, require_text, valid_repository_slug,
};
use crate::task_board::{TaskBoardExecutionPhase, TaskBoardWorkflowKind};

pub(crate) const REMOTE_SOURCE_MATERIAL_SCHEMA_VERSION: u32 = 1;
const GIT_BUNDLE_MEDIA_TYPE: &str = "application/x-git-bundle";

/// Immutable, host-independent source identity for one remote attempt.
///
/// Repository sources never contain controller-local paths. Prior-phase source is represented by
/// a bounded, digest-addressed Git bundle entry carried by the sealed offer manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum RemoteSourceMaterial {
    Repository {
        schema_version: u32,
        repository: String,
        selector: RemoteRepositorySelector,
        revision: String,
    },
    PriorPhaseBundle {
        schema_version: u32,
        repository: String,
        base_revision: String,
        revision: String,
        advertised_ref: String,
        bundle: RemoteArtifactEntry,
    },
    RepositorySnapshotBundle {
        schema_version: u32,
        repository: String,
        revision: String,
        advertised_ref: String,
        bundle: RemoteArtifactEntry,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum RemoteRepositorySelector {
    ExactRevision,
    Branch { branch: String, reference: String },
}

impl RemoteSourceMaterial {
    pub(crate) const fn requires_upload(&self) -> bool {
        matches!(
            self,
            Self::PriorPhaseBundle { .. } | Self::RepositorySnapshotBundle { .. }
        )
    }

    pub(crate) fn repository(&self) -> &str {
        match self {
            Self::Repository { repository, .. }
            | Self::PriorPhaseBundle { repository, .. }
            | Self::RepositorySnapshotBundle { repository, .. } => repository,
        }
    }

    pub(crate) fn repository_revision(repository: &str, revision: &str) -> Self {
        Self::Repository {
            schema_version: REMOTE_SOURCE_MATERIAL_SCHEMA_VERSION,
            repository: repository.to_owned(),
            selector: RemoteRepositorySelector::ExactRevision,
            revision: revision.to_owned(),
        }
    }

    pub(crate) fn repository_branch(repository: &str, branch: &str, revision: &str) -> Self {
        Self::Repository {
            schema_version: REMOTE_SOURCE_MATERIAL_SCHEMA_VERSION,
            repository: repository.to_owned(),
            selector: RemoteRepositorySelector::Branch {
                branch: branch.to_owned(),
                reference: format!("refs/heads/{branch}"),
            },
            revision: revision.to_owned(),
        }
    }

    pub(crate) fn prior_phase_bundle(
        repository: &str,
        base_revision: &str,
        revision: &str,
        bundle: RemoteArtifactEntry,
    ) -> Self {
        Self::PriorPhaseBundle {
            schema_version: REMOTE_SOURCE_MATERIAL_SCHEMA_VERSION,
            repository: repository.to_owned(),
            base_revision: base_revision.to_owned(),
            revision: revision.to_owned(),
            advertised_ref: format!("refs/harness/task-board/results/{revision}"),
            bundle,
        }
    }

    pub(crate) fn repository_snapshot_bundle(
        repository: &str,
        revision: &str,
        bundle: RemoteArtifactEntry,
    ) -> Self {
        Self::RepositorySnapshotBundle {
            schema_version: REMOTE_SOURCE_MATERIAL_SCHEMA_VERSION,
            repository: repository.to_owned(),
            revision: revision.to_owned(),
            advertised_ref: format!("refs/harness/task-board/sources/{revision}"),
            bundle,
        }
    }

    pub(crate) fn validate(
        &self,
        binding: &RemoteAttemptBinding,
        artifacts: &RemoteArtifactManifest,
    ) -> Result<(), RemoteWireError> {
        match self {
            Self::Repository {
                schema_version,
                repository,
                selector,
                revision,
            } => {
                validate_common(*schema_version, repository, revision)?;
                require_binding_repository(binding, repository)?;
                validate_selector(selector)?;
                if requires_prior_phase_bundle(binding) {
                    return Err(RemoteWireError::InvalidSourceMaterial);
                }
                let fork_source = matches!(
                    binding.workflow_kind,
                    TaskBoardWorkflowKind::PrFix | TaskBoardWorkflowKind::PrReview
                );
                if fork_source != matches!(selector, RemoteRepositorySelector::Branch { .. }) {
                    return Err(RemoteWireError::InvalidSourceMaterial);
                }
            }
            Self::PriorPhaseBundle {
                schema_version,
                repository,
                base_revision,
                revision,
                advertised_ref,
                bundle,
            } => {
                validate_common(*schema_version, repository, revision)?;
                require_binding_repository(binding, repository)?;
                validate_revision(base_revision)?;
                if !requires_prior_phase_bundle(binding)
                    || base_revision == revision
                    || binding.base_revision != *revision
                    || advertised_ref != &format!("refs/harness/task-board/results/{revision}")
                    || bundle.media_type != GIT_BUNDLE_MEDIA_TYPE
                    || bundle.size_bytes == 0
                    || !artifacts.entries.iter().any(|entry| entry == bundle)
                {
                    return Err(RemoteWireError::InvalidSourceMaterial);
                }
            }
            Self::RepositorySnapshotBundle {
                schema_version,
                repository,
                revision,
                advertised_ref,
                bundle,
            } => {
                validate_common(*schema_version, repository, revision)?;
                require_binding_repository(binding, repository)?;
                let initial_default_task = binding.workflow_kind == TaskBoardWorkflowKind::DefaultTask
                    && binding.phase == TaskBoardExecutionPhase::Implementation
                    && implementation_cycle(binding) == 1;
                if !initial_default_task
                    || binding.base_revision != *revision
                    || binding.expected_head_revision.is_some()
                    || advertised_ref != &format!("refs/harness/task-board/sources/{revision}")
                    || bundle.media_type != GIT_BUNDLE_MEDIA_TYPE
                    || bundle.size_bytes == 0
                    || !artifacts.entries.iter().any(|entry| entry == bundle)
                {
                    return Err(RemoteWireError::InvalidSourceMaterial);
                }
            }
        }
        Ok(())
    }
}

fn require_binding_repository(
    binding: &RemoteAttemptBinding,
    repository: &str,
) -> Result<(), RemoteWireError> {
    if binding.repository == repository {
        Ok(())
    } else {
        Err(RemoteWireError::InvalidSourceMaterial)
    }
}

fn requires_prior_phase_bundle(binding: &RemoteAttemptBinding) -> bool {
    let write = matches!(
        binding.workflow_kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    );
    match binding.phase {
        TaskBoardExecutionPhase::Implementation => implementation_cycle(binding) > 1,
        TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate => write,
        _ => false,
    }
}

fn implementation_cycle(binding: &RemoteAttemptBinding) -> u32 {
    binding
        .action_key
        .strip_prefix("implementation:")
        .and_then(|cycle| cycle.parse().ok())
        .unwrap_or_default()
}

fn validate_common(
    schema_version: u32,
    repository: &str,
    revision: &str,
) -> Result<(), RemoteWireError> {
    if schema_version != REMOTE_SOURCE_MATERIAL_SCHEMA_VERSION
        || !valid_repository_slug(repository)
    {
        return Err(RemoteWireError::InvalidSourceMaterial);
    }
    require_max_bytes("source_repository", repository, 2_048)?;
    validate_revision(revision)
}

fn validate_revision(revision: &str) -> Result<(), RemoteWireError> {
    require_text("source_revision", revision)?;
    if !matches!(revision.len(), 40 | 64)
        || !revision
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(RemoteWireError::InvalidSourceMaterial);
    }
    Ok(())
}

fn validate_selector(selector: &RemoteRepositorySelector) -> Result<(), RemoteWireError> {
    let RemoteRepositorySelector::Branch { branch, reference } = selector else {
        return Ok(());
    };
    if branch.len() > 1_024
        || !valid_branch(branch)
        || reference != &format!("refs/heads/{branch}")
    {
        return Err(RemoteWireError::InvalidSourceMaterial);
    }
    Ok(())
}

fn valid_branch(branch: &str) -> bool {
    !branch.is_empty()
        && branch != "@"
        && !branch.starts_with(['-', '/', '.'])
        && !branch.ends_with(['/', '.'])
        && branch.bytes().all(|byte| (0x21..=0x7e).contains(&byte))
        && !branch.contains([':', '\\', '~', '^', '?', '*', '['])
        && !branch.contains("..")
        && !branch.contains("//")
        && !branch.contains("@{")
        && branch
            .split('/')
            .all(|component| !component.is_empty() && !component.starts_with('.') && !component.ends_with(".lock"))
}
