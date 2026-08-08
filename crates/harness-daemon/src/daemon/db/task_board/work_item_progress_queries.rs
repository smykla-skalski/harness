//! Work-item progress query surface for [`AsyncDaemonDb`].
//!
//! Daemon callers import this trait through `task_board::prelude`.

use super::work_item_progress::{TaskBoardWorkItemReportRequest, TaskBoardWorkItemReportResult};
use super::{work_item_progress, work_item_progress_settlement};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::{AgentMode, TaskBoardWorkItemProgress};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardPendingWorkerSettlement {
    pub(crate) board_item_id: String,
    pub(crate) work_item_id: String,
    pub(crate) worker_id: String,
    pub(crate) agent_mode: AgentMode,
}

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
    async fn settle_task_board_work_item_worker(
        &self,
        board_item_id: &str,
        work_item_id: &str,
    ) -> Result<(), CliError>;

    /// Load durable worker-stop debts in stable retry order.
    ///
    /// # Errors
    /// Returns [`CliError`] when the rows cannot be read.
    async fn pending_task_board_work_item_worker_settlements(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardPendingWorkerSettlement>, CliError>;

    /// Whether the exact work item is owned by the structured workflow engine.
    ///
    /// # Errors
    /// Returns [`CliError`] when the ownership query fails.
    async fn task_board_work_item_is_workflow_owned(
        &self,
        board_item_id: &str,
        work_item_id: &str,
    ) -> Result<bool, CliError>;
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

    async fn settle_task_board_work_item_worker(
        &self,
        board_item_id: &str,
        work_item_id: &str,
    ) -> Result<(), CliError> {
        work_item_progress_settlement::settle_task_board_work_item_worker(
            self,
            board_item_id,
            work_item_id,
        )
        .await
    }

    async fn pending_task_board_work_item_worker_settlements(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardPendingWorkerSettlement>, CliError> {
        work_item_progress_settlement::pending_task_board_work_item_worker_settlements(self, limit)
            .await
    }

    async fn task_board_work_item_is_workflow_owned(
        &self,
        board_item_id: &str,
        work_item_id: &str,
    ) -> Result<bool, CliError> {
        work_item_progress_settlement::task_board_work_item_is_workflow_owned(
            self,
            board_item_id,
            work_item_id,
        )
        .await
    }
}
