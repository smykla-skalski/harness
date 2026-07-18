use sqlx::{Sqlite, Transaction, query_scalar};

use crate::daemon::db::{CliError, db_error};
use crate::task_board::{TaskBoardWorkflowCasMismatch, TaskBoardWorkflowExecutionRecord};

pub(super) async fn live_execution_revision_mismatch_in_tx(
    transaction: &mut Transaction<'_, Sqlite>,
    execution: &TaskBoardWorkflowExecutionRecord,
) -> Result<Option<TaskBoardWorkflowCasMismatch>, CliError> {
    let item_revision = query_scalar::<_, i64>(
        "SELECT revision FROM task_board_items WHERE item_id = ?1 AND deleted_at IS NULL",
    )
    .bind(&execution.item_id)
    .fetch_optional(transaction.as_mut())
    .await
    .map_err(|error| db_error(format!("read live workflow item revision: {error}")))?;
    if item_revision != Some(execution.snapshot.item_revision) {
        return Ok(Some(TaskBoardWorkflowCasMismatch::ItemRevision));
    }
    let configuration_revision = query_scalar::<_, i64>(
        "SELECT COALESCE((SELECT revision FROM task_board_orchestrator_settings
         WHERE singleton = 1), 0)",
    )
    .fetch_one(transaction.as_mut())
    .await
    .map_err(|error| {
        db_error(format!(
            "read live workflow configuration revision: {error}"
        ))
    })?;
    let expected_configuration = i64::try_from(execution.snapshot.configuration_revision)
        .map_err(|_| db_error("workflow configuration revision is out of range"))?;
    if configuration_revision != expected_configuration {
        return Ok(Some(TaskBoardWorkflowCasMismatch::ConfigurationRevision));
    }
    Ok(None)
}
