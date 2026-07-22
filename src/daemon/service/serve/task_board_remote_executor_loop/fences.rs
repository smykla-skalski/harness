use tokio::sync::watch;

use crate::daemon::db::TaskBoardRemoteAssignmentRecord;
use crate::errors::{CliError, CliErrorKind};

pub(super) fn shutdown_observed(shutdown_rx: Option<&watch::Receiver<bool>>) -> bool {
    shutdown_rx.is_some_and(|receiver| *receiver.borrow())
}

pub(super) fn require_executor_identity(
    record: &TaskBoardRemoteAssignmentRecord,
) -> Result<(), CliError> {
    if record.target_host_instance_id.is_none()
        || record.target_host_instance_id != record.claimed_host_instance_id
    {
        return Err(concurrent(
            "remote assignment is bound to another executor process",
        ));
    }
    Ok(())
}

pub(super) fn concurrent(message: &'static str) -> CliError {
    CliErrorKind::concurrent_modification(message.to_string()).into()
}

pub(super) fn invalid_transition(message: impl Into<String>) -> CliError {
    CliErrorKind::invalid_transition(message.into()).into()
}
