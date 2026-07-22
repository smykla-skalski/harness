use sha2::{Digest, Sha256};
use sqlx::{Sqlite, Transaction, query_scalar};
use uuid::Uuid;

use super::TaskBoardRemoteExecutorIdentity;
use crate::daemon::db::task_board::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, phase_label,
};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardLocalExecutionHostConfig, TaskBoardOrchestratorSettings,
    validate_local_execution_host_config,
};

const START_AUTHORITY_DOMAIN: &str = "harness.task-board.remote-executor-start.v1";

pub(crate) fn remote_executor_identity(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<TaskBoardRemoteExecutorIdentity, CliError> {
    let request_sha256 = record
        .request_sha256
        .as_deref()
        .ok_or_else(|| db_error("remote executor assignment has no offer digest"))?;
    Ok(remote_executor_identity_from_parts(
        &record.assignment_id,
        record.fencing_epoch,
        request_sha256,
    ))
}

pub(crate) fn remote_executor_identity_from_parts(
    assignment_id: &str,
    fencing_epoch: u64,
    request_sha256: &str,
) -> TaskBoardRemoteExecutorIdentity {
    let digest = Sha256::digest(format!(
        "harness.task-board.remote-worker.v1\0{assignment_id}\0{fencing_epoch}\0{request_sha256}"
    ));
    let mut uuid_bytes = [0_u8; 16];
    uuid_bytes.copy_from_slice(&digest[..16]);
    uuid_bytes[6] = (uuid_bytes[6] & 0x0f) | 0x50;
    uuid_bytes[8] = (uuid_bytes[8] & 0x3f) | 0x80;
    let suffix = hex::encode(&digest[..16]);
    TaskBoardRemoteExecutorIdentity {
        session_id: Uuid::from_bytes(uuid_bytes).to_string(),
        run_id: format!("remote-codex-{suffix}"),
        workspace_ref: format!("remote-workspace-{suffix}"),
    }
}

pub(crate) async fn executor_settings_still_match(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<bool, CliError> {
    let Some(expected_revision) = record.executor_configuration_revision else {
        return Ok(false);
    };
    let Some(expected_checkout) = record.executor_checkout_path.as_deref() else {
        return Ok(false);
    };
    let (settings, revision) = load_executor_settings(transaction).await?;
    if u64::try_from(revision).ok() != Some(expected_revision) {
        return Ok(false);
    }
    validate_local_execution_host_config(&settings.local_execution_host)?;
    Ok(settings.local_execution_host.enabled
        && executor_launch_material_matches(
            &settings.local_execution_host,
            record,
            expected_checkout,
        )
        && executor_host_row_matches(transaction, record, revision, true).await?)
}

pub(crate) async fn executor_lifecycle_settings_still_compatible(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<bool, CliError> {
    let Some(expected_checkout) = record.executor_checkout_path.as_deref() else {
        return Ok(false);
    };
    let (settings, revision) = load_executor_settings(transaction).await?;
    validate_local_execution_host_config(&settings.local_execution_host)?;
    Ok(
        executor_launch_material_matches(&settings.local_execution_host, record, expected_checkout)
            && executor_host_row_matches(transaction, record, revision, false).await?,
    )
}

async fn load_executor_settings(
    transaction: &mut Transaction<'_, Sqlite>,
) -> Result<(TaskBoardOrchestratorSettings, i64), CliError> {
    let (settings_json, revision) = sqlx::query_as::<_, (String, i64)>(
        "SELECT settings_json, revision FROM task_board_orchestrator_settings WHERE singleton = 1",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("load executor settings before start: {error}")))?;
    let settings = serde_json::from_str::<TaskBoardOrchestratorSettings>(&settings_json)
        .map_err(|error| db_error(format!("decode executor settings before start: {error}")))?;
    Ok((settings, revision))
}

fn executor_launch_material_matches(
    host: &TaskBoardLocalExecutionHostConfig,
    record: &TaskBoardRemoteAssignmentRecord,
    expected_checkout: &str,
) -> bool {
    let Ok(offer) = record.require_offer() else {
        return false;
    };
    host.host_id == record.host_id
        && host
            .runtimes
            .iter()
            .any(|runtime| runtime == &offer.launch.runtime)
        && host.repositories.iter().any(|repository| {
            repository.repository == offer.source.repository()
                && repository.checkout_path == expected_checkout
        })
}

async fn executor_host_row_matches(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    revision: i64,
    require_enabled: bool,
) -> Result<bool, CliError> {
    query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM task_board_execution_hosts
         WHERE host_id = ?1 AND host_role = 'executor_self'
           AND configuration_revision = ?2
           AND (?3 = 0 OR enabled = 1))",
    )
    .bind(&record.host_id)
    .bind(revision)
    .bind(require_enabled)
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify executor identity before start: {error}")))
}

pub(crate) fn start_authority_digest(
    record: &TaskBoardRemoteAssignmentRecord,
    identity: &TaskBoardRemoteExecutorIdentity,
    acquired_at: &str,
) -> Result<String, CliError> {
    let offer = record.require_offer()?;
    let values = [
        START_AUTHORITY_DOMAIN.to_string(),
        record.assignment_id.clone(),
        record.execution_id.clone(),
        phase_label(offer.binding.phase)?.to_string(),
        offer.binding.action_key.clone(),
        offer.binding.attempt.to_string(),
        offer.binding.idempotency_key.clone(),
        record.host_id.clone(),
        required(&record.claimed_host_instance_id, "claimed host")?,
        required(&record.authenticated_principal, "authenticated principal")?,
        required(&record.claimed_at, "claim time")?,
        record.fencing_epoch.to_string(),
        offer.request_sha256.clone(),
        record
            .claim_receipt
            .as_ref()
            .ok_or_else(|| db_error("remote executor start has no claim receipt"))?
            .sha256
            .clone(),
        required(&record.lease_id, "lease")?,
        required(&record.lease_expires_at, "lease expiry")?,
        required(&record.deadline_at, "deadline")?,
        offer.binding.configuration_revision.to_string(),
        record
            .executor_configuration_revision
            .ok_or_else(|| db_error("remote executor start has no executor revision"))?
            .to_string(),
        required(&record.executor_checkout_path, "checkout")?,
        identity.session_id.clone(),
        identity.run_id.clone(),
        identity.workspace_ref.clone(),
        acquired_at.into(),
    ];
    let mut hasher = Sha256::new();
    for value in values {
        hasher.update(value.len().to_be_bytes());
        hasher.update(value.as_bytes());
    }
    Ok(hex::encode(hasher.finalize()))
}

fn required(value: &Option<String>, label: &str) -> Result<String, CliError> {
    value
        .clone()
        .ok_or_else(|| db_error(format!("remote executor start has no {label}")))
}
