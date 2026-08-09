//! Work-item progress query surface for [`AsyncDaemonDb`].
//!
//! Daemon callers import this trait through `task_board::prelude`.

use super::work_item_progress::{TaskBoardWorkItemReportRequest, TaskBoardWorkItemReportResult};
use super::{work_item_progress, work_item_progress_settlement, work_item_progress_terminal};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::{AgentMode, TaskBoardWorkItemProgress, TaskBoardWorkItemState};
use harness_daemon_managed_agents::AgentTuiStatus;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardPendingWorkerSettlement {
    pub(crate) board_item_id: String,
    pub(crate) work_item_id: String,
    pub(crate) worker_id: String,
    pub(crate) agent_mode: AgentMode,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardRuntimeTerminalReport {
    pub(crate) state: TaskBoardWorkItemState,
    pub(crate) summary: Option<String>,
    pub(crate) blocked_reason: Option<String>,
}

impl TaskBoardRuntimeTerminalReport {
    pub(crate) fn from_terminal_agent(
        status: AgentTuiStatus,
        error: Option<&str>,
        signal: Option<&str>,
    ) -> Option<Self> {
        let reason = match status {
            AgentTuiStatus::Exited => "managed terminal agent exited",
            AgentTuiStatus::Failed => "managed terminal agent failed",
            AgentTuiStatus::Stopped => "managed terminal agent stopped",
            AgentTuiStatus::Starting | AgentTuiStatus::Running => return None,
        };
        let detail = error
            .or(signal)
            .map(str::trim)
            .filter(|detail| !detail.is_empty());
        let blocked_reason = detail.map_or_else(
            || format!("{reason} before reporting completion"),
            |detail| format!("{reason} before reporting completion: {detail}"),
        );
        Some(Self {
            state: TaskBoardWorkItemState::Blocked,
            summary: None,
            blocked_reason: Some(blocked_reason),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TaskBoardTerminalWorkerAttempt {
    pub(crate) attempt_id: String,
    pub(crate) report: TaskBoardRuntimeTerminalReport,
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

    /// Load sessionless interactive attempts whose durable runtime is terminal
    /// but whose exact progress row still needs projection.
    ///
    /// # Errors
    /// Returns [`CliError`] when the rows cannot be read or decoded.
    async fn terminal_task_board_worker_attempts(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardTerminalWorkerAttempt>, CliError>;

    /// Whether the exact work item is owned by the structured workflow engine.
    ///
    /// # Errors
    /// Returns [`CliError`] when the ownership query fails.
    async fn task_board_work_item_is_workflow_owned(
        &self,
        board_item_id: &str,
        work_item_id: &str,
    ) -> Result<bool, CliError>;

    /// Project one exact runtime's terminal outcome onto a sessionless work item.
    ///
    /// # Errors
    /// Returns [`CliError`] when the item or progress row cannot be read or written.
    async fn project_task_board_runtime_terminal(
        &self,
        board_item_id: &str,
        work_item_id: &str,
        attempt_id: &str,
        report: &TaskBoardRuntimeTerminalReport,
    ) -> Result<bool, CliError>;

    /// Project a terminal outcome by the interactive runtime's durable attempt id.
    ///
    /// # Errors
    /// Returns [`CliError`] when the attempt is ambiguous or cannot be written.
    async fn project_task_board_runtime_terminal_for_attempt(
        &self,
        attempt_id: &str,
        report: &TaskBoardRuntimeTerminalReport,
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

    async fn terminal_task_board_worker_attempts(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardTerminalWorkerAttempt>, CliError> {
        work_item_progress_settlement::terminal_task_board_worker_attempts(self, limit).await
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

    async fn project_task_board_runtime_terminal(
        &self,
        board_item_id: &str,
        work_item_id: &str,
        attempt_id: &str,
        report: &TaskBoardRuntimeTerminalReport,
    ) -> Result<bool, CliError> {
        work_item_progress_terminal::project_task_board_runtime_terminal(
            self,
            board_item_id,
            work_item_id,
            attempt_id,
            report,
        )
        .await
    }

    async fn project_task_board_runtime_terminal_for_attempt(
        &self,
        attempt_id: &str,
        report: &TaskBoardRuntimeTerminalReport,
    ) -> Result<bool, CliError> {
        work_item_progress_terminal::project_task_board_runtime_terminal_for_attempt(
            self, attempt_id, report,
        )
        .await
    }
}
