use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use harness_kernel::errors::CliError;

pub(super) async fn executor_assignment_ids(
    db: &AsyncDaemonDbHandle,
) -> Result<Vec<String>, CliError> {
    let scan = db.scan_task_board_remote_executor_assignments().await?;
    let mut assignment_ids = scan.active_assignment_ids;
    assignment_ids.extend(scan.terminal_assignment_ids);
    Ok(assignment_ids)
}
