//! Automation scheduler query surface for [`AsyncDaemonDb`], consolidated
//! behind one trait so its real bodies -- spread across `control.rs`,
//! `history.rs`, `metrics.rs`, `recovery.rs`, `runs.rs`, `stages.rs`,
//! `status.rs`, and `status/targets.rs`, and `wake.rs` -- can each stay in
//! the file they already live in. Rust only allows one `impl Trait for
//! Type` block per type, so this file is the single place
//! `TaskBoardAutomationSchedulerQueries` is implemented; every method body
//! is a one-line forward into the plain function that owns the real logic.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.

use chrono::{DateTime, Utc};

use super::{
    TaskBoardAutomationControlRecord, TaskBoardAutomationRunAdmission, TaskBoardAutomationRunFence,
    TaskBoardAutomationRunLease, TaskBoardAutomationRunStage, TaskBoardRunAcquireRequest,
};
use super::{control, history, metrics, recovery, runs, stages, status};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::{
    TaskBoardAutomationCancelTarget, TaskBoardAutomationDesiredMode,
    TaskBoardAutomationHistoryRequest, TaskBoardAutomationHistoryResponse,
    TaskBoardAutomationMetrics, TaskBoardAutomationRunDetail, TaskBoardAutomationRunInfo,
    TaskBoardAutomationRunOutcome, TaskBoardAutomationSnapshot, TaskBoardAutomationWakeEvent,
    TaskBoardAutomationWakeRequest, TaskBoardOrchestratorSettings,
};

pub(crate) trait TaskBoardAutomationSchedulerQueries: Send + Sync {
    async fn initialize_task_board_automation_control_from_legacy_intent(
        &self,
        desired_mode: TaskBoardAutomationDesiredMode,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError>;

    async fn task_board_automation_control(
        &self,
    ) -> Result<TaskBoardAutomationControlRecord, CliError>;

    async fn start_task_board_automation(
        &self,
        desired_mode: TaskBoardAutomationDesiredMode,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError>;

    async fn start_task_board_automation_with_wake(
        &self,
        desired_mode: TaskBoardAutomationDesiredMode,
        wake: &TaskBoardAutomationWakeRequest,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError>;

    async fn replace_task_board_orchestrator_settings_for_automation(
        &self,
        settings: &TaskBoardOrchestratorSettings,
        desired_mode: TaskBoardAutomationDesiredMode,
        now: DateTime<Utc>,
    ) -> Result<i64, CliError>;

    async fn stop_task_board_automation(
        &self,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError>;

    async fn finish_task_board_automation_drain_if_idle(
        &self,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError>;

    async fn active_task_board_automation_run(
        &self,
    ) -> Result<Option<TaskBoardAutomationRunInfo>, CliError>;

    async fn task_board_automation_history(
        &self,
        request: &TaskBoardAutomationHistoryRequest,
    ) -> Result<TaskBoardAutomationHistoryResponse, CliError>;

    async fn task_board_automation_run_detail(
        &self,
        run_id: &str,
    ) -> Result<Option<TaskBoardAutomationRunDetail>, CliError>;

    async fn task_board_automation_metrics(&self) -> Result<TaskBoardAutomationMetrics, CliError>;

    /// Expire coordinator runs left stale across daemon startup.
    async fn recover_stale_task_board_automation_runs(
        &self,
        now: DateTime<Utc>,
    ) -> Result<u64, CliError>;

    async fn try_acquire_task_board_automation_run(
        &self,
        request: &TaskBoardRunAcquireRequest,
    ) -> Result<TaskBoardAutomationRunAdmission, CliError>;

    async fn heartbeat_task_board_automation_run(
        &self,
        lease: &TaskBoardAutomationRunLease,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationRunFence, CliError>;

    async fn finalize_task_board_automation_run(
        &self,
        lease: &TaskBoardAutomationRunLease,
        outcome: TaskBoardAutomationRunOutcome,
        error_kind: Option<&str>,
        error: Option<&str>,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationRunOutcome, CliError>;

    async fn upsert_task_board_automation_run_stage(
        &self,
        lease: &TaskBoardAutomationRunLease,
        stage: &TaskBoardAutomationRunStage,
        now: DateTime<Utc>,
    ) -> Result<u64, CliError>;

    async fn task_board_automation_snapshot(&self)
    -> Result<TaskBoardAutomationSnapshot, CliError>;

    async fn task_board_automation_cancel_target(
        &self,
        execution_id: &str,
    ) -> Result<Option<TaskBoardAutomationCancelTarget>, CliError>;

    async fn enqueue_task_board_automation_wake_event(
        &self,
        request: &TaskBoardAutomationWakeRequest,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationWakeEvent, CliError>;

    async fn pending_task_board_automation_wake_events(
        &self,
        limit: u32,
    ) -> Result<Vec<TaskBoardAutomationWakeEvent>, CliError>;

    async fn acknowledge_task_board_automation_wake_events(
        &self,
        sequences: &[u64],
        processed_at: DateTime<Utc>,
    ) -> Result<u64, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the plain function that actually owns the
/// area's query logic, kept in the file the query has always lived in.
impl TaskBoardAutomationSchedulerQueries for AsyncDaemonDb {
    async fn initialize_task_board_automation_control_from_legacy_intent(
        &self,
        desired_mode: TaskBoardAutomationDesiredMode,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        control::initialize_task_board_automation_control_from_legacy_intent(
            self,
            desired_mode,
            now,
        )
        .await
    }

    async fn task_board_automation_control(
        &self,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        control::task_board_automation_control(self).await
    }

    async fn start_task_board_automation(
        &self,
        desired_mode: TaskBoardAutomationDesiredMode,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        control::start_task_board_automation(self, desired_mode, now).await
    }

    async fn start_task_board_automation_with_wake(
        &self,
        desired_mode: TaskBoardAutomationDesiredMode,
        wake: &TaskBoardAutomationWakeRequest,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        control::start_task_board_automation_with_wake(self, desired_mode, wake, now).await
    }

    async fn replace_task_board_orchestrator_settings_for_automation(
        &self,
        settings: &TaskBoardOrchestratorSettings,
        desired_mode: TaskBoardAutomationDesiredMode,
        now: DateTime<Utc>,
    ) -> Result<i64, CliError> {
        control::replace_task_board_orchestrator_settings_for_automation(
            self,
            settings,
            desired_mode,
            now,
        )
        .await
    }

    async fn stop_task_board_automation(
        &self,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        control::stop_task_board_automation(self, now).await
    }

    async fn finish_task_board_automation_drain_if_idle(
        &self,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationControlRecord, CliError> {
        control::finish_task_board_automation_drain_if_idle(self, now).await
    }

    async fn active_task_board_automation_run(
        &self,
    ) -> Result<Option<TaskBoardAutomationRunInfo>, CliError> {
        history::active_task_board_automation_run(self).await
    }

    async fn task_board_automation_history(
        &self,
        request: &TaskBoardAutomationHistoryRequest,
    ) -> Result<TaskBoardAutomationHistoryResponse, CliError> {
        history::task_board_automation_history(self, request).await
    }

    async fn task_board_automation_run_detail(
        &self,
        run_id: &str,
    ) -> Result<Option<TaskBoardAutomationRunDetail>, CliError> {
        history::task_board_automation_run_detail(self, run_id).await
    }

    async fn task_board_automation_metrics(&self) -> Result<TaskBoardAutomationMetrics, CliError> {
        metrics::task_board_automation_metrics(self).await
    }

    async fn recover_stale_task_board_automation_runs(
        &self,
        now: DateTime<Utc>,
    ) -> Result<u64, CliError> {
        recovery::recover_stale_task_board_automation_runs(self, now).await
    }

    async fn try_acquire_task_board_automation_run(
        &self,
        request: &TaskBoardRunAcquireRequest,
    ) -> Result<TaskBoardAutomationRunAdmission, CliError> {
        runs::try_acquire_task_board_automation_run(self, request).await
    }

    async fn heartbeat_task_board_automation_run(
        &self,
        lease: &TaskBoardAutomationRunLease,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationRunFence, CliError> {
        runs::heartbeat_task_board_automation_run(self, lease, now).await
    }

    async fn finalize_task_board_automation_run(
        &self,
        lease: &TaskBoardAutomationRunLease,
        outcome: TaskBoardAutomationRunOutcome,
        error_kind: Option<&str>,
        error: Option<&str>,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationRunOutcome, CliError> {
        runs::finalize_task_board_automation_run(self, lease, outcome, error_kind, error, now).await
    }

    async fn upsert_task_board_automation_run_stage(
        &self,
        lease: &TaskBoardAutomationRunLease,
        stage: &TaskBoardAutomationRunStage,
        now: DateTime<Utc>,
    ) -> Result<u64, CliError> {
        stages::upsert_task_board_automation_run_stage(self, lease, stage, now).await
    }

    async fn task_board_automation_snapshot(
        &self,
    ) -> Result<TaskBoardAutomationSnapshot, CliError> {
        status::task_board_automation_snapshot(self).await
    }

    async fn task_board_automation_cancel_target(
        &self,
        execution_id: &str,
    ) -> Result<Option<TaskBoardAutomationCancelTarget>, CliError> {
        status::targets::task_board_automation_cancel_target(self, execution_id).await
    }

    async fn enqueue_task_board_automation_wake_event(
        &self,
        request: &TaskBoardAutomationWakeRequest,
        now: DateTime<Utc>,
    ) -> Result<TaskBoardAutomationWakeEvent, CliError> {
        super::wake::enqueue_task_board_automation_wake_event(self, request, now).await
    }

    async fn pending_task_board_automation_wake_events(
        &self,
        limit: u32,
    ) -> Result<Vec<TaskBoardAutomationWakeEvent>, CliError> {
        super::wake::pending_task_board_automation_wake_events(self, limit).await
    }

    async fn acknowledge_task_board_automation_wake_events(
        &self,
        sequences: &[u64],
        processed_at: DateTime<Utc>,
    ) -> Result<u64, CliError> {
        super::wake::acknowledge_task_board_automation_wake_events(self, sequences, processed_at)
            .await
    }
}
