//! Workflow execution query surface for [`AsyncDaemonDb`], consolidated
//! behind one trait so its real bodies -- spread across `workflow_executions.rs`,
//! `workflow_execution_attempts.rs`, `workflow_execution_candidates.rs`,
//! `workflow_execution_audited_cancel.rs`, `workflow_recovery_selection.rs`,
//! `workflow_target_selection.rs`, `workflow_terminal.rs`,
//! `workflow_dispatch_settlement.rs`, and `workflow_side_effect_claims.rs`
//! -- can each stay in the file they already live in. Rust only allows one
//! `impl Trait for Type` block per type, so this file is the single place
//! `WorkflowExecutionQueries` is implemented; every method body is a
//! one-line forward into the plain function that owns the real logic.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.

use super::workflow_execution_audited_cancel::{
    self, AuditedRemoteCancelCasOutcome,
};
use super::workflow_terminal::{self, TaskBoardWorkflowTerminalProjection};
use super::{
    workflow_dispatch_settlement, workflow_execution_attempts, workflow_execution_candidates,
    workflow_executions, workflow_recovery_selection, workflow_side_effect_claims,
    workflow_target_selection,
};
use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::daemon::protocol::HarnessMonitorAuditEvent;
use crate::task_board::{
    TaskBoardAutomationCancelTarget, TaskBoardExecutionAttemptCas,
    TaskBoardExecutionAttemptCasOutcome, TaskBoardExecutionAttemptCreateOutcome,
    TaskBoardExecutionAttemptRecord, TaskBoardItem, TaskBoardWorkflowExecutionCas,
    TaskBoardWorkflowExecutionCasOutcome, TaskBoardWorkflowExecutionCreateOutcome,
    TaskBoardWorkflowExecutionRecord,
};

pub(crate) trait WorkflowExecutionQueries: Send + Sync {
    async fn create_or_load_task_board_workflow_execution(
        &self,
        proposed: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardWorkflowExecutionCreateOutcome, CliError>;

    async fn task_board_workflow_execution(
        &self,
        execution_id: &str,
    ) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError>;

    async fn active_task_board_workflow_execution(
        &self,
        item_id: &str,
    ) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError>;

    async fn compare_and_set_task_board_workflow_execution(
        &self,
        expected: &TaskBoardWorkflowExecutionCas,
        updated: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError>;

    async fn task_board_configuration_revision(&self) -> Result<u64, CliError>;

    async fn create_task_board_execution_attempt(
        &self,
        proposed: &TaskBoardExecutionAttemptRecord,
    ) -> Result<TaskBoardExecutionAttemptCreateOutcome, CliError>;

    async fn compare_and_set_task_board_execution_attempt(
        &self,
        expected: &TaskBoardExecutionAttemptCas,
        updated: &TaskBoardExecutionAttemptRecord,
    ) -> Result<TaskBoardExecutionAttemptCasOutcome, CliError>;

    async fn compare_and_set_task_board_workflow_execution_and_attempt(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        updated_execution: &TaskBoardWorkflowExecutionRecord,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        updated_attempt: &TaskBoardExecutionAttemptRecord,
    ) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError>;

    async fn ready_task_board_workflow_executions(
        &self,
        now: &str,
        limit: usize,
    ) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError>;

    async fn projectable_task_board_read_only_workflow_executions(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError>;

    async fn compare_and_set_task_board_remote_cancel_with_audit(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        target: &TaskBoardAutomationCancelTarget,
        updated_execution: &TaskBoardWorkflowExecutionRecord,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        updated_attempt: &TaskBoardExecutionAttemptRecord,
        audit: &HarnessMonitorAuditEvent,
    ) -> Result<AuditedRemoteCancelCasOutcome, CliError>;

    async fn recoverable_task_board_workflow_executions(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError>;

    async fn remote_candidate_task_board_workflow_executions(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError>;

    /// Selects the exact local target before any local runtime side effect is claimable.
    async fn select_task_board_local_execution_target(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        selected_at: &str,
    ) -> Result<bool, CliError>;

    async fn recover_orphaned_task_board_read_only_workflow_admissions(
        &self,
    ) -> Result<Vec<String>, CliError>;

    async fn project_task_board_read_only_workflow_terminal(
        &self,
        execution_id: &str,
    ) -> Result<TaskBoardWorkflowTerminalProjection, CliError>;

    /// Persist a workflow execution and its first attempt without charging admission.
    async fn prepare_task_board_workflow_dispatch(
        &self,
        intent_id: &str,
        claim_token: &str,
    ) -> Result<TaskBoardItem, CliError>;

    /// Commit admission only after the exact local or remote worker durably started.
    async fn complete_task_board_workflow_dispatch_start(
        &self,
        execution_id: &str,
    ) -> Result<bool, CliError>;

    async fn claim_task_board_workflow_side_effect(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        claimed_attempt: &TaskBoardExecutionAttemptRecord,
        now: &str,
    ) -> Result<Option<TaskBoardExecutionAttemptRecord>, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the plain function that actually owns the
/// area's query logic, kept in the file the query has always lived in.
impl WorkflowExecutionQueries for AsyncDaemonDb {
    async fn create_or_load_task_board_workflow_execution(
        &self,
        proposed: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardWorkflowExecutionCreateOutcome, CliError> {
        workflow_executions::create_or_load_task_board_workflow_execution(self, proposed).await
    }

    async fn task_board_workflow_execution(
        &self,
        execution_id: &str,
    ) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError> {
        workflow_executions::task_board_workflow_execution(self, execution_id).await
    }

    async fn active_task_board_workflow_execution(
        &self,
        item_id: &str,
    ) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError> {
        workflow_executions::active_task_board_workflow_execution(self, item_id).await
    }

    async fn compare_and_set_task_board_workflow_execution(
        &self,
        expected: &TaskBoardWorkflowExecutionCas,
        updated: &TaskBoardWorkflowExecutionRecord,
    ) -> Result<TaskBoardWorkflowExecutionCasOutcome, CliError> {
        workflow_executions::compare_and_set_task_board_workflow_execution(self, expected, updated)
            .await
    }

    async fn task_board_configuration_revision(&self) -> Result<u64, CliError> {
        workflow_executions::task_board_configuration_revision(self).await
    }

    async fn create_task_board_execution_attempt(
        &self,
        proposed: &TaskBoardExecutionAttemptRecord,
    ) -> Result<TaskBoardExecutionAttemptCreateOutcome, CliError> {
        workflow_execution_attempts::create_task_board_execution_attempt(self, proposed).await
    }

    async fn compare_and_set_task_board_execution_attempt(
        &self,
        expected: &TaskBoardExecutionAttemptCas,
        updated: &TaskBoardExecutionAttemptRecord,
    ) -> Result<TaskBoardExecutionAttemptCasOutcome, CliError> {
        workflow_execution_attempts::compare_and_set_task_board_execution_attempt(
            self, expected, updated,
        )
        .await
    }

    async fn compare_and_set_task_board_workflow_execution_and_attempt(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        updated_execution: &TaskBoardWorkflowExecutionRecord,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        updated_attempt: &TaskBoardExecutionAttemptRecord,
    ) -> Result<Option<TaskBoardWorkflowExecutionRecord>, CliError> {
        workflow_execution_attempts::compare_and_set_task_board_workflow_execution_and_attempt(
            self,
            expected_execution,
            updated_execution,
            expected_attempt,
            updated_attempt,
        )
        .await
    }

    async fn ready_task_board_workflow_executions(
        &self,
        now: &str,
        limit: usize,
    ) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError> {
        workflow_execution_candidates::ready_task_board_workflow_executions(self, now, limit).await
    }

    async fn projectable_task_board_read_only_workflow_executions(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError> {
        workflow_execution_candidates::projectable_task_board_read_only_workflow_executions(
            self, limit,
        )
        .await
    }

    async fn compare_and_set_task_board_remote_cancel_with_audit(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        target: &TaskBoardAutomationCancelTarget,
        updated_execution: &TaskBoardWorkflowExecutionRecord,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        updated_attempt: &TaskBoardExecutionAttemptRecord,
        audit: &HarnessMonitorAuditEvent,
    ) -> Result<AuditedRemoteCancelCasOutcome, CliError> {
        Box::pin(
            workflow_execution_audited_cancel::compare_and_set_task_board_remote_cancel_with_audit(
                self,
                expected_execution,
                target,
                updated_execution,
                expected_attempt,
                updated_attempt,
                audit,
            ),
        )
        .await
    }

    async fn recoverable_task_board_workflow_executions(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError> {
        workflow_recovery_selection::recoverable_task_board_workflow_executions(self, limit).await
    }

    async fn remote_candidate_task_board_workflow_executions(
        &self,
        limit: usize,
    ) -> Result<Vec<TaskBoardWorkflowExecutionRecord>, CliError> {
        workflow_recovery_selection::remote_candidate_task_board_workflow_executions(self, limit)
            .await
    }

    async fn select_task_board_local_execution_target(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        selected_at: &str,
    ) -> Result<bool, CliError> {
        workflow_target_selection::select_task_board_local_execution_target(
            self,
            expected_execution,
            expected_attempt,
            selected_at,
        )
        .await
    }

    async fn recover_orphaned_task_board_read_only_workflow_admissions(
        &self,
    ) -> Result<Vec<String>, CliError> {
        workflow_terminal::recover_orphaned_task_board_read_only_workflow_admissions(self).await
    }

    async fn project_task_board_read_only_workflow_terminal(
        &self,
        execution_id: &str,
    ) -> Result<TaskBoardWorkflowTerminalProjection, CliError> {
        workflow_terminal::project_task_board_read_only_workflow_terminal(self, execution_id).await
    }

    async fn prepare_task_board_workflow_dispatch(
        &self,
        intent_id: &str,
        claim_token: &str,
    ) -> Result<TaskBoardItem, CliError> {
        workflow_dispatch_settlement::prepare_task_board_workflow_dispatch(
            self,
            intent_id,
            claim_token,
        )
        .await
    }

    async fn complete_task_board_workflow_dispatch_start(
        &self,
        execution_id: &str,
    ) -> Result<bool, CliError> {
        workflow_dispatch_settlement::complete_task_board_workflow_dispatch_start(
            self,
            execution_id,
        )
        .await
    }

    async fn claim_task_board_workflow_side_effect(
        &self,
        expected_execution: &TaskBoardWorkflowExecutionCas,
        expected_attempt: &TaskBoardExecutionAttemptCas,
        claimed_attempt: &TaskBoardExecutionAttemptRecord,
        now: &str,
    ) -> Result<Option<TaskBoardExecutionAttemptRecord>, CliError> {
        workflow_side_effect_claims::claim_task_board_workflow_side_effect(
            self,
            expected_execution,
            expected_attempt,
            claimed_attempt,
            now,
        )
        .await
    }
}
