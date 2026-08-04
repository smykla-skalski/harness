use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::protocol::{
    TaskBoardGitRuntimeSecretHandoffAckRequest, TaskBoardGitRuntimeSecretHandoffAckResponse,
    TaskBoardGitRuntimeSecretHandoffPrepareResponse, TaskBoardGitSigningVerifyRequest,
    TaskBoardGitSigningVerifyResponse,
};
use crate::daemon::state;
use crate::task_board::TaskBoardGitRuntimeConfig;
use harness_kernel::errors::CliError;
use harness_task_board_git_runtime::{
    handoff_error, normalized_runtime_config, pending_legacy_secret_runtime,
    signing_verify_response, validated_repository,
};

#[cfg(test)]
pub use harness_task_board_git_runtime::{
    git_runtime_profile_for_repository, task_board_git_runtime_config,
    update_task_board_git_runtime_config, validate_repository_tokens,
    verify_task_board_git_signing,
};
pub use harness_task_board_git_runtime::{
    sync_task_board_git_runtime_key_material, sync_task_board_github_tokens,
    sync_task_board_openrouter_token, task_board_git_identity_defaults,
};

pub(crate) async fn task_board_git_runtime_config_db(
    db: &AsyncDaemonDb,
) -> Result<TaskBoardGitRuntimeConfig, CliError> {
    let mut config = db.task_board_runtime_config().await?;
    state::overlay_task_board_git_runtime_secret_flags(&mut config);
    Ok(config)
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

fn required_handoff_field(value: Option<String>, field: &str) -> Result<String, CliError> {
    value.ok_or_else(|| handoff_error(format!("pending Task Board secret handoff has no {field}")))
}

#[cfg(test)]
mod tests;
