use sqlx::query;

use super::remote_assignment_model::{
    TaskBoardRemoteAssignmentRecord, canonical_time, concurrent, to_i64,
};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteAssignmentWireState, RemoteStatusRequest, RemoteStatusResponse,
};
use crate::task_board::TaskBoardRemoteAssignmentState;

pub(super) fn status_update_allowed(
    record: &TaskBoardRemoteAssignmentRecord,
    response: &RemoteStatusResponse,
) -> Result<bool, CliError> {
    let target = durable_state(response.state);
    if !state_transition_allowed(record.state, target) {
        return Ok(false);
    }
    status_non_state_evidence_allowed(record, response)
}

pub(super) fn status_non_state_evidence_allowed(
    record: &TaskBoardRemoteAssignmentRecord,
    response: &RemoteStatusResponse,
) -> Result<bool, CliError> {
    if record.offer.as_ref().map(|offer| &offer.binding) != Some(&response.binding)
        || record.target_host_instance_id.as_deref()
            != Some(response.binding.host_instance_id.as_str())
    {
        return Ok(false);
    }
    let observed = canonical_time(&response.observed_at, "remote status observation time")?;
    if canonical_time(&record.updated_at, "durable assignment update time")? > observed {
        return Ok(false);
    }
    if !stable_optional_copy(record.claimed_at.as_deref(), response.claimed_at.as_deref())
        || !stable_optional_copy(record.started_at.as_deref(), response.started_at.as_deref())
        || !stable_optional_copy(
            record.workspace_ref.as_deref(),
            response.workspace_ref.as_deref(),
        )
    {
        return Ok(false);
    }
    if let Some(claimed) = response.claimed_at.as_deref() {
        let claimed = canonical_time(claimed, "remote claim evidence time")?;
        if claimed > observed {
            return Ok(false);
        }
        if let Some(started) = response.started_at.as_deref() {
            let started = canonical_time(started, "remote start evidence time")?;
            if started < claimed || started > observed {
                return Ok(false);
            }
        }
    }
    if let Some(lease) = &response.lease {
        let deadline = record
            .deadline_at
            .as_deref()
            .ok_or_else(|| db_error("remote assignment deadline is missing"))?;
        if canonical_time(&lease.expires_at, "remote status lease expiry")?
            > canonical_time(deadline, "remote assignment deadline")?
        {
            return Ok(false);
        }
    }
    Ok(true)
}

fn stable_optional_copy(current: Option<&str>, observed: Option<&str>) -> bool {
    current.is_none_or(|current| observed == Some(current))
}

const fn durable_state(state: RemoteAssignmentWireState) -> TaskBoardRemoteAssignmentState {
    match state {
        RemoteAssignmentWireState::Offered => TaskBoardRemoteAssignmentState::Offered,
        RemoteAssignmentWireState::Claimed => TaskBoardRemoteAssignmentState::Claimed,
        RemoteAssignmentWireState::Running => TaskBoardRemoteAssignmentState::Running,
        RemoteAssignmentWireState::Completed => TaskBoardRemoteAssignmentState::Completed,
        RemoteAssignmentWireState::Failed => TaskBoardRemoteAssignmentState::Failed,
        RemoteAssignmentWireState::Cancelled => TaskBoardRemoteAssignmentState::Cancelled,
        RemoteAssignmentWireState::Superseded => TaskBoardRemoteAssignmentState::Superseded,
        RemoteAssignmentWireState::Unknown => TaskBoardRemoteAssignmentState::Unknown,
    }
}

fn state_transition_allowed(
    current: TaskBoardRemoteAssignmentState,
    target: TaskBoardRemoteAssignmentState,
) -> bool {
    if current == target {
        return !matches!(
            current,
            TaskBoardRemoteAssignmentState::Completed
                | TaskBoardRemoteAssignmentState::Failed
                | TaskBoardRemoteAssignmentState::Cancelled
                | TaskBoardRemoteAssignmentState::Superseded
                | TaskBoardRemoteAssignmentState::Unknown
        );
    }
    match current {
        TaskBoardRemoteAssignmentState::Offered => true,
        TaskBoardRemoteAssignmentState::Claimed
        | TaskBoardRemoteAssignmentState::Started
        | TaskBoardRemoteAssignmentState::Running => !matches!(
            target,
            TaskBoardRemoteAssignmentState::Offered
                | TaskBoardRemoteAssignmentState::Claimed
                | TaskBoardRemoteAssignmentState::Started
        ),
        TaskBoardRemoteAssignmentState::Unknown => matches!(
            target,
            TaskBoardRemoteAssignmentState::Completed
                | TaskBoardRemoteAssignmentState::Failed
                | TaskBoardRemoteAssignmentState::Cancelled
        ),
        TaskBoardRemoteAssignmentState::Completed
        | TaskBoardRemoteAssignmentState::Failed
        | TaskBoardRemoteAssignmentState::Cancelled
        | TaskBoardRemoteAssignmentState::Superseded => false,
    }
}

pub(super) async fn persist_status(
    transaction: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    record: &TaskBoardRemoteAssignmentRecord,
    request: &RemoteStatusRequest,
    response: &RemoteStatusResponse,
) -> Result<(), CliError> {
    let state = durable_state(response.state);
    let terminal = matches!(
        state,
        TaskBoardRemoteAssignmentState::Completed
            | TaskBoardRemoteAssignmentState::Failed
            | TaskBoardRemoteAssignmentState::Cancelled
            | TaskBoardRemoteAssignmentState::Superseded
    );
    let result_sha256 = response
        .result
        .as_ref()
        .map(|result| result.result_sha256.as_str());
    let status_json = serde_json::to_string(response)
        .map_err(|error| db_error(format!("serialize remote assignment status: {error}")))?;
    let claimed_at = response
        .claimed_at
        .as_deref()
        .or(record.claimed_at.as_deref());
    let started_at = response
        .started_at
        .as_deref()
        .or(record.started_at.as_deref());
    let workspace_ref = response
        .workspace_ref
        .as_deref()
        .or(record.workspace_ref.as_deref());
    let claimed_instance = claimed_at.map(|_| response.binding.host_instance_id.as_str());
    let rows = query(
        "UPDATE task_board_remote_assignments SET state = ?2,
         claimed_host_instance_id = ?3, claimed_at = ?4, started_at = ?5,
         workspace_ref = ?6, lease_id = ?7, lease_expires_at = ?8,
         heartbeat_at = ?9, completed_at = ?10, result_json = ?11,
         status_sha256 = ?12, result_sha256 = ?13, error = ?14, updated_at = ?9
         WHERE assignment_id = ?1 AND fencing_epoch = ?15 AND state = ?16
         AND lease_id = ?17 AND lease_expires_at = ?18",
    )
    .bind(&record.assignment_id)
    .bind(state.as_str())
    .bind(claimed_instance)
    .bind(claimed_at)
    .bind(started_at)
    .bind(workspace_ref)
    .bind(&record.lease_id)
    .bind(&record.lease_expires_at)
    .bind(&response.observed_at)
    .bind(terminal.then_some(response.observed_at.as_str()))
    .bind(status_json)
    .bind(&response.status_sha256)
    .bind(result_sha256)
    .bind(&response.error_code)
    .bind(to_i64(record.fencing_epoch, "assignment fencing epoch")?)
    .bind(record.state.as_str())
    .bind(&request.lease_id)
    .bind(&record.lease_expires_at)
    .execute(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("persist remote assignment status: {error}")))?
    .rows_affected();
    if rows == 1 {
        Ok(())
    } else {
        Err(concurrent("remote assignment status update lost its fence"))
    }
}
