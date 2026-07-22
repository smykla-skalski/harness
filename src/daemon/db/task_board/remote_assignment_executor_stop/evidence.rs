use sha2::{Digest, Sha256};
use sqlx::{Sqlite, Transaction, query_as};

use super::{TaskBoardRemoteExecutorStopPending, stop_pending_digest};
use crate::daemon::db::task_board::remote_assignment_model::TaskBoardRemoteAssignmentRecord;
use crate::daemon::db::task_board::remote_assignment_start_authority::remote_executor_identity;
use crate::daemon::db::{CliError, db_error};
use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot};
use crate::task_board::TaskBoardRemoteAssignmentState;

const OBSERVED_LAUNCH_DOMAIN: &str = "harness.task-board.remote-executor-observed-launch.v1";

type StoredLaunchEvidence = (
    String,
    String,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    String,
    String,
    String,
    String,
    Option<String>,
    Option<String>,
);

pub(super) async fn durable_run_matches_snapshot(
    transaction: &mut Transaction<'_, Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    snapshot: &CodexRunSnapshot,
) -> Result<bool, CliError> {
    let identity = remote_executor_identity(record)?;
    if snapshot.run_id != identity.run_id || snapshot.session_id != identity.session_id {
        return Ok(false);
    }
    let Some(stored) = stored_launch_evidence(
        transaction,
        &snapshot.run_id,
        &snapshot.session_id,
        false,
    )
    .await?
    else {
        return Ok(false);
    };
    Ok(observed_launch_digest(snapshot) == stored_launch_digest(&stored))
}

pub(super) async fn durable_stopped_run_matches(
    transaction: &mut Transaction<'_, Sqlite>,
    _record: &TaskBoardRemoteAssignmentRecord,
    pending: &TaskBoardRemoteExecutorStopPending,
) -> Result<bool, CliError> {
    let Some(stored) = stored_launch_evidence(
        transaction,
        &pending.run_id,
        &pending.session_id,
        true,
    )
    .await?
    else {
        return Ok(false);
    };
    Ok(stored_launch_digest(&stored) == pending.observed_launch_sha256)
}

pub(super) fn observed_launch_digest(snapshot: &CodexRunSnapshot) -> String {
    launch_digest(&[
        Some(snapshot.run_id.as_str()),
        Some(snapshot.session_id.as_str()),
        snapshot.task_id.as_deref(),
        snapshot.board_item_id.as_deref(),
        snapshot.workflow_execution_id.as_deref(),
        snapshot.display_name.as_deref(),
        Some(snapshot.project_dir.as_str()),
        Some(mode_label(snapshot.mode)),
        Some(snapshot.prompt.as_str()),
        Some(snapshot.created_at.as_str()),
        snapshot.model.as_deref(),
        snapshot.effort.as_deref(),
    ])
}

pub(super) fn settled_stop_replays(
    record: &TaskBoardRemoteAssignmentRecord,
    pending: &TaskBoardRemoteExecutorStopPending,
) -> Result<bool, CliError> {
    let offer = record.require_offer()?;
    let identity = remote_executor_identity(record)?;
    let claim = record
        .claim_receipt
        .as_ref()
        .ok_or_else(|| db_error("settled remote executor stop has no claim receipt"))?;
    Ok(record.state == TaskBoardRemoteAssignmentState::Unknown
        && record.fencing_epoch == pending.fencing_epoch
        && offer.request_sha256 == pending.offer_request_sha256
        && claim.sha256 == pending.claim_receipt_sha256
        && record.start_receipt.as_ref().map(|receipt| receipt.sha256.as_str())
            == pending.start_receipt_sha256.as_deref()
        && record.executor_start_authority_sha256.is_none()
        && record.executor_start_io_permit_sha256.is_none()
        && record.executor_lifecycle_owner.is_none()
        && record.executor_stop_pending.is_none()
        && record.executor_configuration_revision == Some(pending.executor_configuration_revision)
        && record.executor_checkout_path.as_deref()
            == Some(pending.executor_checkout_path.as_str())
        && offer.source == pending.source
        && identity.session_id == pending.session_id
        && identity.run_id == pending.run_id
        && identity.workspace_ref == pending.workspace_ref
        && record.error.as_deref() == Some(pending.reason.message())
        && stop_pending_digest(pending)? == pending.sha256)
}

async fn stored_launch_evidence(
    transaction: &mut Transaction<'_, Sqlite>,
    run_id: &str,
    session_id: &str,
    require_terminal: bool,
) -> Result<Option<StoredLaunchEvidence>, CliError> {
    query_as::<_, StoredLaunchEvidence>(
        "SELECT runs.run_id, runs.session_id, runs.task_id, runs.board_item_id,
                runs.workflow_execution_id, runs.display_name, runs.project_dir,
                runs.mode, runs.prompt, runs.created_at, runs.model, runs.effort
         FROM codex_runs AS runs
         JOIN sessions ON sessions.session_id = runs.session_id
         WHERE runs.run_id = ?1 AND runs.session_id = ?2
           AND (?3 = 0 OR runs.status IN ('completed', 'failed', 'cancelled'))
           AND json_valid(sessions.state_json)
           AND json_extract(sessions.state_json, '$.session_id') = runs.session_id
           AND json_extract(sessions.state_json, '$.worktree_path') = runs.project_dir",
    )
    .bind(run_id)
    .bind(session_id)
    .bind(require_terminal)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("verify remote executor stop run: {error}")))
}

fn stored_launch_digest(stored: &StoredLaunchEvidence) -> String {
    launch_digest(&[
        Some(stored.0.as_str()),
        Some(stored.1.as_str()),
        stored.2.as_deref(),
        stored.3.as_deref(),
        stored.4.as_deref(),
        stored.5.as_deref(),
        Some(stored.6.as_str()),
        Some(stored.7.as_str()),
        Some(stored.8.as_str()),
        Some(stored.9.as_str()),
        stored.10.as_deref(),
        stored.11.as_deref(),
    ])
}

fn launch_digest(values: &[Option<&str>]) -> String {
    let mut hasher = Sha256::new();
    update_required(&mut hasher, OBSERVED_LAUNCH_DOMAIN);
    for value in values {
        match value {
            Some(value) => {
                hasher.update([1]);
                update_required(&mut hasher, value);
            }
            None => hasher.update([0]),
        }
    }
    hex::encode(hasher.finalize())
}

fn update_required(hasher: &mut Sha256, value: &str) {
    hasher.update(value.len().to_be_bytes());
    hasher.update(value.as_bytes());
}

const fn mode_label(mode: CodexRunMode) -> &'static str {
    match mode {
        CodexRunMode::Report => "report",
        CodexRunMode::WorkspaceWrite => "workspace_write",
        CodexRunMode::Approval => "approval",
    }
}
