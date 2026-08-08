//! Work-item progress query surface for [`AsyncDaemonDb`].
//!
//! Daemon callers import this trait through `task_board::prelude`.

use super::work_item_progress;
use super::work_item_progress::{TaskBoardWorkItemReportRequest, TaskBoardWorkItemReportResult};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::TaskBoardWorkItemProgress;

pub(crate) trait WorkItemProgressQueries: Send + Sync {
    /// Read the durable worker progress for one board item, if it has been
    /// dispatched.
    ///
    /// # Errors
    /// Returns [`CliError`] when the record cannot be read.
    async fn task_board_work_item_progress(
        &self,
        board_item_id: &str,
    ) -> Result<Option<TaskBoardWorkItemProgress>, CliError>;

    /// Apply one worker report to the record and project it onto the item.
    ///
    /// # Errors
    /// Returns [`CliError`] when the item is missing, was never dispatched, or
    /// the write fails.
    async fn report_task_board_work_item_progress(
        &self,
        request: &TaskBoardWorkItemReportRequest,
    ) -> Result<TaskBoardWorkItemReportResult, CliError>;

    /// Mark a settled work item's managed worker as stopped.
    ///
    /// # Errors
    /// Returns [`CliError`] when the write fails.
    async fn settle_task_board_work_item_worker(&self, work_item_id: &str) -> Result<(), CliError>;
}

impl WorkItemProgressQueries for AsyncDaemonDb {
    async fn task_board_work_item_progress(
        &self,
        board_item_id: &str,
    ) -> Result<Option<TaskBoardWorkItemProgress>, CliError> {
        work_item_progress::task_board_work_item_progress(self, board_item_id).await
    }

    async fn report_task_board_work_item_progress(
        &self,
        request: &TaskBoardWorkItemReportRequest,
    ) -> Result<TaskBoardWorkItemReportResult, CliError> {
        work_item_progress::report_task_board_work_item_progress(self, request).await
    }

    async fn settle_task_board_work_item_worker(&self, work_item_id: &str) -> Result<(), CliError> {
        work_item_progress::settle_task_board_work_item_worker(self, work_item_id).await
    }
}
