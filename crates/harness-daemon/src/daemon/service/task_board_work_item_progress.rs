//! Worker progress reporting and one-shot settlement.
//!
//! The durable write and the board projection happen together in the database
//! layer. What is left here is the part that cannot be transactional: stopping
//! the managed worker behind a work item that just settled. The record tracks
//! whether that stop still owes, so a crash between the two retries it and a
//! completed one is never repeated.

use tracing::warn;

use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db::task_board::work_item_progress::TaskBoardWorkItemReportRequest as DbReportRequest;
use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    TaskBoardWorkItemProgressResponse, TaskBoardWorkItemReportRequest,
    TaskBoardWorkItemReportResponse,
};
use crate::daemon::task_board_managed_agents::stop_managed_worker;
use crate::session::types::CONTROL_PLANE_ACTOR_ID;
use harness_kernel::errors::CliError;

/// Read the durable worker progress for one board item.
///
/// # Errors
/// Returns [`CliError`] when the item or its record cannot be read.
pub(crate) async fn get_task_board_work_item_progress_db(
    db: &AsyncDaemonDbHandle,
    board_item_id: &str,
) -> Result<TaskBoardWorkItemProgressResponse, CliError> {
    Ok(TaskBoardWorkItemProgressResponse {
        progress: db.task_board_work_item_progress(board_item_id).await?,
    })
}

/// Apply one worker report, then settle the managed worker if the report just
/// settled the work item.
///
/// # Errors
/// Returns [`CliError`] when the item is missing, was never dispatched, or the
/// durable write fails. A refused report is not an error: the caller reads the
/// rejection and the current record off the response.
pub(crate) async fn report_task_board_work_item_progress_db(
    state: &DaemonHttpState,
    db: &AsyncDaemonDbHandle,
    board_item_id: &str,
    request: &TaskBoardWorkItemReportRequest,
) -> Result<TaskBoardWorkItemReportResponse, CliError> {
    let result = db
        .report_task_board_work_item_progress(&DbReportRequest {
            board_item_id: board_item_id.to_string(),
            actor: request
                .actor
                .clone()
                .unwrap_or_else(|| CONTROL_PLANE_ACTOR_ID.to_string()),
            state: request.state,
            summary: request.summary.clone(),
            progress_percent: request.progress_percent,
            blocked_reason: request.blocked_reason.clone(),
            sequence: request.sequence,
        })
        .await?;
    if let Some(worker_id) = result.pending_worker_settlement.as_deref() {
        settle_worker(
            state,
            db,
            &result.progress.work_item_id,
            worker_id,
            &result.item,
        )
        .await;
    }
    Ok(TaskBoardWorkItemReportResponse {
        applied: result.applied,
        rejection: result.rejection,
        rejection_message: result
            .rejection
            .map(|rejection| rejection.message().to_string()),
        progress: result.progress,
    })
}

/// Stops the worker and marks the debt paid. A failed stop is logged rather
/// than surfaced: the work item is already settled and the record is already
/// correct, so failing the caller's report would misreport durable state. The
/// debt stays unpaid, so the next report retries the stop.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
async fn settle_worker(
    state: &DaemonHttpState,
    db: &AsyncDaemonDbHandle,
    work_item_id: &str,
    worker_id: &str,
    item: &crate::task_board::TaskBoardItem,
) {
    if let Err(error) = stop_managed_worker(
        state,
        item.agent_mode,
        worker_id.to_string(),
        "task-board work item settlement",
    )
    .await
    {
        warn!(
            board_item_id = %item.id,
            work_item_id,
            worker_id,
            error = %error,
            "task-board work item settled but its worker could not be stopped"
        );
        return;
    }
    if let Err(error) = db.settle_task_board_work_item_worker(work_item_id).await {
        warn!(
            board_item_id = %item.id,
            work_item_id,
            worker_id,
            error = %error,
            "task-board work item worker stopped but the settlement could not be recorded"
        );
    }
}
