use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{TaskBoardTriageCurrentResponse, TaskBoardTriageHistoryResponse};
use crate::errors::CliError;
use crate::infra::io::validate_safe_segment;

pub(crate) async fn get_task_board_item_triage_current_db(
    db: &AsyncDaemonDb,
    item_id: &str,
) -> Result<TaskBoardTriageCurrentResponse, CliError> {
    validate_safe_segment(item_id)?;
    let current = db.task_board_triage_current(item_id).await?;
    Ok(TaskBoardTriageCurrentResponse { current })
}

pub(crate) async fn get_task_board_item_triage_history_db(
    db: &AsyncDaemonDb,
    item_id: &str,
    before_generation: Option<u64>,
    limit: u32,
) -> Result<TaskBoardTriageHistoryResponse, CliError> {
    validate_safe_segment(item_id)?;
    let page = db
        .task_board_triage_history(item_id, before_generation, limit)
        .await?;
    Ok(TaskBoardTriageHistoryResponse {
        decisions: page.decisions,
        next_before_generation: page.next_before_generation,
    })
}
