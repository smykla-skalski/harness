use std::collections::BTreeSet;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{
    TaskBoardGitRuntimeKeyMaterialSyncRequest, TaskBoardGitRuntimeKeyMaterialSyncResponse,
    TaskBoardGitRuntimeSecretHandoffAckRequest, TaskBoardGitRuntimeSecretHandoffAckResponse,
    TaskBoardGitRuntimeSecretHandoffPrepareResponse, TaskBoardGitSigningVerifyRequest,
    TaskBoardGitSigningVerifyResponse,
};
use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::github::{SigningVerifyOutcome, verify_signing_for_profile};
use crate::task_board::{
    ExternalProvider, ExternalSyncConfig, TaskBoardGitHubRepositoryToken,
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitHubTokensSyncResponse,
    TaskBoardGitIdentityDefaults, TaskBoardGitRepositoryOverride, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeProfile, TaskBoardOpenRouterTokenSyncRequest,
    TaskBoardOpenRouterTokenSyncResponse, TaskBoardTodoistTokenSyncRequest,
    TaskBoardTodoistTokenSyncResponse, discover_git_identity_defaults, normalize_repository_slug,
};

/// Load the persisted task-board git runtime config.
///
/// # Errors
/// Returns `CliError` when the daemon runtime config cannot be read.
#[cfg(test)]
pub fn task_board_git_runtime_config() -> Result<TaskBoardGitRuntimeConfig, CliError> {
    state::load_task_board_git_runtime_config()
}

/// Load Task Board Git runtime configuration from the canonical daemon database.
/// Process-only secret presence is overlaid after the durable read.
pub(crate) async fn task_board_git_runtime_config_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardGitRuntimeConfig, CliError> {
    let mut config = db.task_board_runtime_config().await?;
    state::overlay_task_board_git_runtime_secret_flags(&mut config);
    Ok(config)
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
#[cfg(test)]
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

pub(crate) async fn verify_task_board_git_signing_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardGitSigningVerifyRequest,
) -> Result<TaskBoardGitSigningVerifyResponse, CliError> {
    let repository = validated_repository(request.repository.as_deref())?;
    let config = db.task_board_runtime_config().await?;
    let mut profile = config.resolved_profile(repository);
    state::overlay_task_board_git_runtime_profile_secrets(&mut profile, repository);
    Ok(signing_verify_response(&profile))
}

/// Prepare a non-destructive legacy-secret handoff to the Monitor secure store.
pub(crate) async fn prepare_task_board_git_runtime_secret_handoff(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardGitRuntimeSecretHandoffPrepareResponse, CliError> {
    let Some(marker) = db.pending_task_board_secret_handoff().await? else {
        return Ok(TaskBoardGitRuntimeSecretHandoffPrepareResponse {
            prepared: false,
            migration_id: None,
            digest: None,
            runtime: TaskBoardGitRuntimeConfig::default(),
        });
    };
    let migration_id = required_handoff_field(marker.secret_handoff_id, "migration id")?;
    let digest = required_handoff_field(marker.secret_handoff_digest, "digest")?;
    let runtime = pending_legacy_secret_runtime(&digest)?;
    Ok(TaskBoardGitRuntimeSecretHandoffPrepareResponse {
        prepared: true,
        migration_id: Some(migration_id),
        digest: Some(digest),
        runtime,
    })
}

/// Acknowledge a prepared handoff and retire the legacy file envelope only
/// after the acknowledgement is durable in `SQLite`.
pub(crate) async fn acknowledge_task_board_git_runtime_secret_handoff(
    db: &AsyncDaemonDb,
    request: &TaskBoardGitRuntimeSecretHandoffAckRequest,
) -> Result<TaskBoardGitRuntimeSecretHandoffAckResponse, CliError> {
    let marker = db
        .task_board_secret_handoff(&request.migration_id)
        .await?
        .ok_or_else(|| handoff_error("Task Board secret handoff is stale"))?;
    if marker.secret_handoff_digest.as_deref() != Some(request.digest.as_str()) {
        return Err(handoff_error(
            "Task Board secret handoff digest does not match",
        ));
    }
    if marker.secret_handoff_phase == "complete" {
        return Ok(TaskBoardGitRuntimeSecretHandoffAckResponse { acknowledged: true });
    }

    if marker.secret_handoff_phase == "pending" {
        let runtime = pending_legacy_secret_runtime(&request.digest)?;
        db.acknowledge_task_board_secret_handoff(&request.migration_id, &request.digest)
            .await?;
        state::replace_task_board_git_runtime_secrets(&runtime);
    }
    state::remove_migrated_task_board_config_after_ack(&request.digest)?;
    db.complete_task_board_secret_handoff(&request.migration_id)
        .await?;
    Ok(TaskBoardGitRuntimeSecretHandoffAckResponse { acknowledged: true })
}

fn pending_legacy_secret_runtime(digest: &str) -> Result<TaskBoardGitRuntimeConfig, CliError> {
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

fn required_handoff_field(value: Option<String>, field: &str) -> Result<String, CliError> {
    value.ok_or_else(|| handoff_error(format!("pending Task Board secret handoff has no {field}")))
}

fn handoff_error(message: impl Into<String>) -> CliError {
    CliError::from(CliErrorKind::workflow_parse(message.into()))
}

/// Persist the task-board git runtime config after validation and normalization.
///
/// # Errors
/// Returns `CliError` when repository overrides are invalid/duplicated or the
/// daemon runtime config cannot be written.
#[cfg(test)]
pub fn update_task_board_git_runtime_config(
    request: &TaskBoardGitRuntimeConfig,
) -> Result<TaskBoardGitRuntimeConfig, CliError> {
    let normalized = normalized_runtime_config(request)?;
    let persisted = normalized.without_secrets();
    state::persist_task_board_git_runtime_config(&persisted)?;
    state::replace_task_board_git_runtime_secrets(&normalized);
    Ok(persisted)
}

pub(crate) async fn update_task_board_git_runtime_config_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardGitRuntimeConfig,
) -> Result<TaskBoardGitRuntimeConfig, CliError> {
    let retained = state::retaining_task_board_git_runtime_secrets(request);
    let normalized = normalized_runtime_config(&retained)?;
    let mut response = normalized.without_secrets();
    db.replace_task_board_runtime_config(&response).await?;
    state::replace_task_board_git_runtime_secrets(&normalized);
    state::overlay_task_board_git_runtime_secret_flags(&mut response);
    Ok(response)
}

/// Replace process-only runtime key material without mutating the durable
/// database-backed Git configuration.
pub(crate) fn sync_task_board_git_runtime_key_material(
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

/// Replace the in-memory Todoist token snapshot used by the daemon.
///
/// # Errors
/// This function is currently infallible but returns a `Result` to keep the
/// daemon route signatures aligned with `sync_task_board_github_tokens`.
pub fn sync_task_board_todoist_token(
    request: &TaskBoardTodoistTokenSyncRequest,
) -> Result<TaskBoardTodoistTokenSyncResponse, CliError> {
    Ok(state::replace_task_board_todoist_token(request))
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

pub(crate) fn external_sync_config_for_repository(
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
    config = config.with_github_inbox_repositories_override(inbox_repositories);
    if config.token_for(ExternalProvider::Todoist).is_none()
        && let Some(token) = state::task_board_todoist_token()
    {
        config = config.with_todoist_token_override(Some(token.as_str()));
    }
    config
}

#[cfg(test)]
pub(crate) fn git_runtime_profile_for_repository(
    repository: Option<&str>,
) -> Result<TaskBoardGitRuntimeProfile, CliError> {
    state::task_board_git_runtime_profile(repository)
}

fn normalized_runtime_config(
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

fn validated_repository(repository: Option<&str>) -> Result<Option<&str>, CliError> {
    if let Some(repository) = repository
        && normalize_repository_slug(Some(repository)).is_none()
    {
        return Err(CliError::from(CliErrorKind::workflow_parse(format!(
            "invalid task-board repository '{repository}', expected owner/repo"
        ))));
    }
    Ok(repository)
}

fn signing_verify_response(
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

fn validate_repository_tokens(tokens: &[TaskBoardGitHubRepositoryToken]) -> Result<(), CliError> {
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

#[cfg(test)]
mod tests;
