use std::collections::BTreeSet;

use harness_daemon_state as state;
use harness_kernel::errors::{CliError, CliErrorKind};
use harness_task_board::external::{ExternalProvider, ExternalSyncConfig};
use harness_task_board::github::{SigningVerifyOutcome, verify_signing_for_profile};
#[cfg(any(test, feature = "test-support"))]
use harness_task_board::wire::TaskBoardGitSigningVerifyRequest;
use harness_task_board::wire::TaskBoardGitSigningVerifyResponse;
#[cfg(feature = "daemon-runtime")]
use harness_task_board::wire::{
    TaskBoardGitRuntimeKeyMaterialSyncRequest, TaskBoardGitRuntimeKeyMaterialSyncResponse,
};
use harness_task_board::{
    TaskBoardGitHubRepositoryToken, TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitHubTokensSyncResponse, TaskBoardGitIdentityDefaults,
    TaskBoardGitRepositoryOverride, TaskBoardGitRuntimeConfig, TaskBoardGitRuntimeProfile,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOpenRouterTokenSyncResponse,
    discover_git_identity_defaults, normalize_repository_slug,
};

/// Load the persisted task-board git runtime config.
///
/// # Errors
/// Returns `CliError` when the daemon runtime config cannot be read.
#[cfg(any(test, feature = "test-support"))]
pub fn task_board_git_runtime_config() -> Result<TaskBoardGitRuntimeConfig, CliError> {
    state::load_task_board_git_runtime_config()
}

/// Discover the system-level git identity defaults (git config, gh CLI,
/// `~/.ssh/id_*`, env vars). Used by the UI as placeholder values; never
/// returns secret material.
///
/// # Errors
/// This function is currently infallible but returns a `Result` for parity
/// with the rest of the task-board service surface, so route wiring stays
/// uniform.
pub fn task_board_git_identity_defaults() -> Result<TaskBoardGitIdentityDefaults, CliError> {
    Ok(discover_git_identity_defaults())
}

/// Run a dry-run signing test against the currently-configured profile so
/// the UI can confirm key + passphrase + mode line up after Save.
///
/// # Errors
/// Returns `CliError` only when the requested repository slug is malformed.
/// Signing failures are surfaced inside [`TaskBoardGitSigningVerifyResponse::Failed`]
/// so the UI can render them as a banner without crashing the call.
#[cfg(any(test, feature = "test-support"))]
pub fn verify_task_board_git_signing(
    request: &TaskBoardGitSigningVerifyRequest,
) -> Result<TaskBoardGitSigningVerifyResponse, CliError> {
    let repository = request.repository.as_deref();
    if let Some(repository) = repository
        && normalize_repository_slug(Some(repository)).is_none()
    {
        return Err(CliError::from(CliErrorKind::workflow_parse(format!(
            "invalid task-board repository '{repository}', expected owner/repo"
        ))));
    }
    let profile = state::task_board_git_runtime_profile(repository)?;
    Ok(match verify_signing_for_profile(&profile) {
        SigningVerifyOutcome::Skipped => TaskBoardGitSigningVerifyResponse::Skipped,
        SigningVerifyOutcome::Signed {
            mode,
            signature_kind,
        } => TaskBoardGitSigningVerifyResponse::Signed {
            mode,
            signature_kind,
        },
        SigningVerifyOutcome::Failed { message } => {
            TaskBoardGitSigningVerifyResponse::Failed { message }
        }
    })
}

/// Load and verify the pending legacy secret payload for `digest`.
///
/// # Errors
/// Returns `CliError` when the legacy payload is missing or changed.
#[cfg(feature = "daemon-runtime")]
pub fn pending_legacy_secret_runtime(digest: &str) -> Result<TaskBoardGitRuntimeConfig, CliError> {
    let runtime = state::load_runtime_config_raw()?
        .and_then(|config| config.task_board_git_runtime_config)
        .ok_or_else(|| handoff_error("pending Task Board secret handoff has no legacy payload"))?;
    let actual =
        state::task_board_git_runtime_secret_handoff_digest(&runtime)?.ok_or_else(|| {
            handoff_error("pending Task Board secret handoff has no plaintext secrets")
        })?;
    if actual != digest {
        return Err(handoff_error(
            "pending Task Board secret handoff payload changed",
        ));
    }
    Ok(runtime)
}

#[must_use]
/// Build a workflow error for an invalid secret-handoff request.
pub fn handoff_error(message: impl Into<String>) -> CliError {
    CliError::from(CliErrorKind::workflow_parse(message.into()))
}

/// Persist the task-board git runtime config after validation and normalization.
///
/// # Errors
/// Returns `CliError` when repository overrides are invalid/duplicated or the
/// daemon runtime config cannot be written.
#[cfg(any(test, feature = "test-support"))]
pub fn update_task_board_git_runtime_config(
    request: &TaskBoardGitRuntimeConfig,
) -> Result<TaskBoardGitRuntimeConfig, CliError> {
    let normalized = normalized_runtime_config(request)?;
    let persisted = normalized.without_secrets();
    state::persist_task_board_git_runtime_config(&persisted)?;
    state::replace_task_board_git_runtime_secrets(&normalized);
    Ok(persisted)
}

/// Replace process-only runtime key material without mutating the durable
/// database-backed Git configuration.
///
/// # Errors
/// Returns `CliError` when the supplied runtime configuration is invalid.
#[cfg(feature = "daemon-runtime")]
pub fn sync_task_board_git_runtime_key_material(
    request: &TaskBoardGitRuntimeKeyMaterialSyncRequest,
) -> Result<TaskBoardGitRuntimeKeyMaterialSyncResponse, CliError> {
    let retained = state::retaining_task_board_git_runtime_secrets(&request.runtime);
    let normalized = normalized_runtime_config(&retained)?;
    state::replace_task_board_git_runtime_secrets(&normalized);
    Ok(TaskBoardGitRuntimeKeyMaterialSyncResponse { synchronized: true })
}

/// Replace the in-memory GitHub token snapshot used by the daemon.
///
/// # Errors
/// Returns `CliError` when repository token overrides are invalid.
pub fn sync_task_board_github_tokens(
    request: &TaskBoardGitHubTokensSyncRequest,
) -> Result<TaskBoardGitHubTokensSyncResponse, CliError> {
    validate_repository_tokens(&request.repository_tokens)?;
    Ok(state::replace_task_board_github_tokens(request))
}

/// Replace the in-memory `OpenRouter` API key snapshot used by the daemon's
/// `OpenRouter` managed-agent backend.
///
/// # Errors
/// This function is currently infallible but returns a `Result` to keep the
/// daemon route signatures aligned with the other token-sync surfaces.
pub fn sync_task_board_openrouter_token(
    request: &TaskBoardOpenRouterTokenSyncRequest,
) -> Result<TaskBoardOpenRouterTokenSyncResponse, CliError> {
    Ok(state::replace_task_board_openrouter_token(request))
}

/// Resolve external-sync configuration with the process-local GitHub token
/// snapshot for a repository.
#[must_use]
pub fn external_sync_config_for_repository(
    repository: Option<&str>,
    inbox_repositories: &[String],
) -> ExternalSyncConfig {
    let repository = normalize_repository_slug(repository);
    let mut config = ExternalSyncConfig::from_env();
    if let Some(token) = repository
        .as_deref()
        .and_then(state::task_board_github_repository_token)
        .or_else(|| {
            config
                .token_for(ExternalProvider::GitHub)
                .is_none()
                .then(|| state::task_board_github_token(None))
                .flatten()
        })
    {
        config = config.with_github_token_override(Some(token.as_str()));
    }
    if let Some(repository) = repository.as_deref() {
        config = config.with_github_repository_override(Some(repository));
    }
    config.with_github_inbox_repositories_override(inbox_repositories)
}

/// Resolve the effective Git runtime profile for a repository.
///
/// # Errors
/// Returns `CliError` when the persisted runtime configuration cannot be read.
#[cfg(any(test, feature = "test-support"))]
pub fn git_runtime_profile_for_repository(
    repository: Option<&str>,
) -> Result<TaskBoardGitRuntimeProfile, CliError> {
    state::task_board_git_runtime_profile(repository)
}

/// Normalize and validate a runtime configuration.
///
/// # Errors
/// Returns `CliError` for malformed or duplicate repository overrides.
pub fn normalized_runtime_config(
    request: &TaskBoardGitRuntimeConfig,
) -> Result<TaskBoardGitRuntimeConfig, CliError> {
    let global = request.global.normalized();
    let overrides = request
        .repository_overrides
        .iter()
        .map(|override_config| {
            override_config.normalized().ok_or_else(|| {
                CliError::from(CliErrorKind::workflow_parse(format!(
                    "invalid task-board repository override '{}', expected owner/repo",
                    override_config.repository
                )))
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    validate_unique_overrides(&overrides)?;
    Ok(TaskBoardGitRuntimeConfig {
        global,
        repository_overrides: overrides,
    })
}

/// Validate an optional repository slug.
///
/// # Errors
/// Returns `CliError` when the repository is not an `owner/repo` slug.
pub fn validated_repository(repository: Option<&str>) -> Result<Option<&str>, CliError> {
    if let Some(repository) = repository
        && normalize_repository_slug(Some(repository)).is_none()
    {
        return Err(CliError::from(CliErrorKind::workflow_parse(format!(
            "invalid task-board repository '{repository}', expected owner/repo"
        ))));
    }
    Ok(repository)
}

#[must_use]
/// Convert an internal signing-verification outcome into its wire response.
pub fn signing_verify_response(
    profile: &TaskBoardGitRuntimeProfile,
) -> TaskBoardGitSigningVerifyResponse {
    match verify_signing_for_profile(profile) {
        SigningVerifyOutcome::Skipped => TaskBoardGitSigningVerifyResponse::Skipped,
        SigningVerifyOutcome::Signed {
            mode,
            signature_kind,
        } => TaskBoardGitSigningVerifyResponse::Signed {
            mode,
            signature_kind,
        },
        SigningVerifyOutcome::Failed { message } => {
            TaskBoardGitSigningVerifyResponse::Failed { message }
        }
    }
}

fn validate_unique_overrides(overrides: &[TaskBoardGitRepositoryOverride]) -> Result<(), CliError> {
    let mut seen = BTreeSet::new();
    for override_config in overrides {
        if !seen.insert(override_config.repository.clone()) {
            return Err(CliError::from(CliErrorKind::workflow_parse(format!(
                "duplicate task-board repository override '{}'",
                override_config.repository
            ))));
        }
    }
    Ok(())
}

/// Validate repository-specific GitHub token overrides.
///
/// # Errors
/// Returns `CliError` for malformed, empty, or duplicate overrides.
pub fn validate_repository_tokens(
    tokens: &[TaskBoardGitHubRepositoryToken],
) -> Result<(), CliError> {
    let mut seen = BTreeSet::new();
    for token in tokens {
        let Some(repository) = normalize_repository_slug(Some(token.repository.as_str())) else {
            return Err(CliError::from(CliErrorKind::workflow_parse(format!(
                "invalid task-board repository token override '{}', expected owner/repo",
                token.repository
            ))));
        };
        if token.token.trim().is_empty() {
            return Err(CliError::from(CliErrorKind::workflow_parse(format!(
                "task-board repository token override '{repository}' cannot be empty"
            ))));
        }
        if !seen.insert(repository.clone()) {
            return Err(CliError::from(CliErrorKind::workflow_parse(format!(
                "duplicate task-board repository token override '{repository}'"
            ))));
        }
    }
    Ok(())
}
