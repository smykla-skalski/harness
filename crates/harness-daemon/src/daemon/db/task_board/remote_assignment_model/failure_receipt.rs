use super::TaskBoardRemoteAssignmentRecord;
use crate::daemon::db::{CliError, db_error};

/// Projects the validated no-run receipt into the terminal status read surface.
pub(super) fn apply_start_failure_receipt(
    mut record: TaskBoardRemoteAssignmentRecord,
) -> Result<TaskBoardRemoteAssignmentRecord, CliError> {
    let Some(receipt) = super::super::remote_start_failure_receipts::decode_start_failure_receipt(
        &record,
        record.executor_start_failure_receipt_json.clone(),
        record.executor_start_failure_receipt_sha256.clone(),
    )?
    else {
        return Ok(record);
    };
    if record.status_response.is_some() {
        return Err(db_error(
            "remote assignment carries both a result and a no-run failure receipt",
        ));
    }
    record.status_response = Some(receipt.status_response.clone());
    record.start_failure_receipt = Some(receipt);
    Ok(record)
}
