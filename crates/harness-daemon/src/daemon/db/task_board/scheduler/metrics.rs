use chrono::Utc;
use sqlx::query_as;

use crate::daemon::db::{AsyncDaemonDb, CliError, db_error};
use crate::task_board::TaskBoardAutomationMetrics;

#[derive(sqlx::FromRow)]
struct AutomationMetricsRow {
    runs_total: i64,
    runs_running: i64,
    runs_completed: i64,
    runs_noop: i64,
    runs_partial: i64,
    runs_failed: i64,
    runs_cancelled: i64,
    open_conflicts: i64,
}

impl AsyncDaemonDb {
    pub(crate) async fn task_board_automation_metrics(
        &self,
    ) -> Result<TaskBoardAutomationMetrics, CliError> {
        let row = query_as::<_, AutomationMetricsRow>(
            "SELECT
                (SELECT COUNT(*) FROM task_board_orchestrator_runs) AS runs_total,
                (SELECT COUNT(*) FROM task_board_orchestrator_runs
                    WHERE state IN ('running', 'cancelling')) AS runs_running,
                (SELECT COUNT(*) FROM task_board_orchestrator_runs
                    WHERE state = 'terminal' AND outcome = 'completed') AS runs_completed,
                (SELECT COUNT(*) FROM task_board_orchestrator_runs
                    WHERE state = 'terminal' AND outcome = 'noop') AS runs_noop,
                (SELECT COUNT(*) FROM task_board_orchestrator_runs
                    WHERE state = 'terminal' AND outcome = 'partial') AS runs_partial,
                (SELECT COUNT(*) FROM task_board_orchestrator_runs
                    WHERE state = 'terminal' AND outcome = 'failed') AS runs_failed,
                (SELECT COUNT(*) FROM task_board_orchestrator_runs
                    WHERE state = 'terminal' AND outcome = 'cancelled') AS runs_cancelled,
                (SELECT COUNT(*) FROM task_board_sync_conflicts
                    WHERE state = 'open') AS open_conflicts",
        )
        .fetch_one(self.pool())
        .await
        .map_err(|error| db_error(format!("load task board automation metrics: {error}")))?;
        let captured_at = Utc::now();
        Ok(TaskBoardAutomationMetrics {
            runs_total: metric_count(row.runs_total, "runs total")?,
            runs_running: metric_count(row.runs_running, "runs running")?,
            runs_completed: metric_count(row.runs_completed, "runs completed")?,
            runs_noop: metric_count(row.runs_noop, "runs noop")?,
            runs_partial: metric_count(row.runs_partial, "runs partial")?,
            runs_failed: metric_count(row.runs_failed, "runs failed")?,
            runs_cancelled: metric_count(row.runs_cancelled, "runs cancelled")?,
            open_conflicts: metric_count(row.open_conflicts, "open conflicts")?,
            captured_at: captured_at.to_rfc3339(),
        })
    }
}

fn metric_count(value: i64, name: &str) -> Result<u64, CliError> {
    u64::try_from(value)
        .map_err(|error| db_error(format!("parse task board automation {name}: {error}")))
}
