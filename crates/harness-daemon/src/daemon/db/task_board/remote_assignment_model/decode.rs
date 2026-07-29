use super::{RemoteAssignmentRow, parse_error, to_i64};
use crate::daemon::db::{CliError, db_error};
use crate::daemon::task_board_remote_transport::wire::{
    RemoteOfferRequest, RemoteStatusRequest, RemoteStatusResponse,
    TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::TaskBoardExecutionPhase;

pub(super) fn decode_offer(json: &str) -> Result<RemoteOfferRequest, CliError> {
    let offer = serde_json::from_str::<RemoteOfferRequest>(json)
        .map_err(|error| db_error(format!("decode remote assignment offer: {error}")))?;
    offer
        .validate()
        .map_err(|error| db_error(format!("validate remote assignment offer: {error}")))?;
    Ok(offer)
}

pub(super) fn decode_status(
    json: &str,
    offer: Option<&RemoteOfferRequest>,
    lease_id: Option<&str>,
    lease_expires_at: Option<&str>,
) -> Result<RemoteStatusResponse, CliError> {
    let status = serde_json::from_str::<RemoteStatusResponse>(json)
        .map_err(|error| db_error(format!("decode remote assignment result: {error}")))?;
    let offer = offer.ok_or_else(|| db_error("remote result has no offer evidence"))?;
    let expected = RemoteStatusRequest {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        binding: offer.binding.clone(),
        lease_id: lease_id.unwrap_or("legacy-missing-lease").to_owned(),
        offer_request_sha256: offer.request_sha256.clone(),
        request_sha256: "0".repeat(64),
    };
    status
        .validate(&expected)
        .map_err(|error| db_error(format!("validate remote assignment result: {error}")))?;
    if status.lease.as_ref().is_some_and(|lease| {
        lease_id != Some(lease.lease_id.as_str())
            || lease_expires_at != Some(lease.expires_at.as_str())
    }) {
        return Err(db_error(
            "remote assignment result lease differs from durable lease evidence",
        ));
    }
    Ok(status)
}

pub(super) fn validate_offer_copies(
    row: &RemoteAssignmentRow,
    offer: Option<&RemoteOfferRequest>,
) -> Result<(), CliError> {
    if row.legacy_migrated {
        return if offer.is_none() && row.state == "superseded" {
            Ok(())
        } else {
            Err(db_error("legacy remote assignment shape is inconsistent"))
        };
    }
    let offer = offer.ok_or_else(|| db_error("remote assignment offer evidence is missing"))?;
    let binding = &offer.binding;
    let matches = binding.assignment_id == row.assignment_id
        && binding.execution_id == row.execution_id
        && phase_label(binding.phase)? == row.phase
        && row.action_key.as_deref() == Some(binding.action_key.as_str())
        && row.attempt == Some(i64::from(binding.attempt))
        && binding.idempotency_key == row.idempotency_key
        && binding.host_id == row.host_id
        && row.target_host_instance_id.as_deref() == Some(binding.host_instance_id.as_str())
        && row.fencing_epoch == to_i64(binding.fencing_epoch, "assignment fencing epoch")?
        && row.configuration_revision
            == Some(to_i64(
                binding.configuration_revision,
                "assignment configuration revision",
            )?)
        && row.execution_record_sha256.as_deref() == Some(binding.execution_record_sha256.as_str())
        && row.request_sha256.as_deref() == Some(offer.request_sha256.as_str());
    if matches {
        Ok(())
    } else {
        Err(db_error("remote assignment row diverges from sealed offer"))
    }
}

pub(super) fn decode_phase(value: &str) -> Result<TaskBoardExecutionPhase, CliError> {
    match value {
        "implementation" => Ok(TaskBoardExecutionPhase::Implementation),
        "review" => Ok(TaskBoardExecutionPhase::Review),
        "evaluate" => Ok(TaskBoardExecutionPhase::Evaluate),
        _ => Err(db_error(format!(
            "invalid durable remote assignment phase '{value}'"
        ))),
    }
}

pub(crate) fn phase_label(phase: TaskBoardExecutionPhase) -> Result<&'static str, CliError> {
    match phase {
        TaskBoardExecutionPhase::Implementation => Ok("implementation"),
        TaskBoardExecutionPhase::Review => Ok("review"),
        TaskBoardExecutionPhase::Evaluate => Ok("evaluate"),
        _ => Err(parse_error("phase cannot be assigned remotely")),
    }
}

pub(super) fn positive_u32(value: i64, field: &str) -> Result<u32, CliError> {
    u32::try_from(value)
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(|| db_error(format!("{field} is out of range")))
}

pub(super) fn positive_u64(value: i64, field: &str) -> Result<u64, CliError> {
    u64::try_from(value)
        .ok()
        .filter(|value| *value > 0)
        .ok_or_else(|| db_error(format!("{field} is out of range")))
}
