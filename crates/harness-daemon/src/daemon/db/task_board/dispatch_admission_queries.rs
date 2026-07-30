//! The dispatch and admission-ledger cluster's own interface onto
//! [`AsyncDaemonDb`]: the operations `service`, the HTTP worker-start route,
//! and `codex_controller` already call to enqueue, claim, admit, prepare and
//! settle a task-board worker dispatch.
//!
//! `task_board` doesn't own `AsyncDaemonDb` -- it's a sibling module's type --
//! so an inherent `impl AsyncDaemonDb` block for this cluster's queries can
//! never move into a crate `task_board` doesn't share with `db`. A trait
//! `task_board` itself declares has no such problem: Rust's orphan rule only
//! requires one of the trait or the implementing type to be local, and the
//! trait is. That is what lets this cluster's queries move into their own
//! crate later without dragging every other area's inherent impls along for
//! the ride, the same way [`super::provider_queries::ProviderQueries`] does
//! for the provider-sync area.
//!
//! `AsyncDaemonDb` keeps its original inherent methods too, each now a thin
//! forward into the matching trait method, so nothing outside `db/task_board`
//! has to change to keep calling them by the same name.
//!
//! This is the cluster's *first* boundary. Its second, narrower boundary is
//! [`super::dispatch_admission_tx_ext::TaskBoardDispatchAdmissionTxExt`],
//! which exposes the transaction-scoped admission and reservation helpers
//! that the item core, triage, workflow-execution and provider-sync areas
//! already reach into by name today. The two are separate because they solve
//! different problems: this trait is the cluster's public API surface, the
//! extension trait is the internal fan-in every sibling area already depends
//! on. Folding the second into the first would force every sibling to depend
//! on the cluster's *entire* public surface just to reach one reservation
//! check.

use crate::daemon::db::{AsyncDaemonDb, CliError};
use crate::task_board::dispatch::DispatchLifecycle;
use crate::task_board::{
    DispatchAppliedTask, DispatchPlan, TaskBoardHeldDispatchSummary, TaskBoardItem,
    TaskBoardLaunchCapability, TaskBoardReadOnlyWorkflowLaunch, TaskBoardWriteWorkflowLaunch,
};

use super::admission_recovery::{
    TaskBoardAdmissionMissingRunRecovery, TaskBoardAdmissionWorkerRecovery,
};
use super::dispatch_intents::ClaimedTaskBoardDispatch;
use super::dispatch_preparation_claim::TaskBoardPreparationClaim;
use super::dispatch_preparations::{
    ClaimedTaskBoardDispatchPreparation, ReservedTaskBoardDispatch, TaskBoardPreparationRelease,
};
use super::held_dispatch::{ClaimedHeldTaskBoardDispatch, HeldTaskBoardDispatch};

pub(crate) trait DispatchAdmissionQueries: Send + Sync {
    async fn release_task_board_admission_for_managed_worker(
        &self,
        managed_worker_id: &str,
    ) -> Result<bool, CliError>;

    async fn validate_task_board_dispatch_admission_start(
        &self,
        intent_id: &str,
        claim_token: &str,
        actual_capability: Option<TaskBoardLaunchCapability>,
        expected_read_only_fence: Option<(i64, u64)>,
    ) -> Result<(), CliError>;

    async fn task_board_admission_worker_recoveries(
        &self,
    ) -> Result<Vec<TaskBoardAdmissionWorkerRecovery>, CliError>;

    async fn reconcile_missing_task_board_admission_worker(
        &self,
        expected: &TaskBoardAdmissionWorkerRecovery,
        reason: &str,
    ) -> Result<Option<TaskBoardAdmissionMissingRunRecovery>, CliError>;

    async fn link_and_enqueue_task_board_dispatch(
        &self,
        board_item_id: &str,
        session_id: &str,
        work_item_id: &str,
        lifecycle: &DispatchLifecycle,
    ) -> Result<DispatchAppliedTask, CliError>;

    async fn claim_task_board_dispatch(
        &self,
        board_item_id: &str,
    ) -> Result<Option<ClaimedTaskBoardDispatch>, CliError>;

    async fn claim_next_task_board_dispatch(
        &self,
    ) -> Result<Option<ClaimedTaskBoardDispatch>, CliError>;

    async fn complete_task_board_dispatch(
        &self,
        intent_id: &str,
        claim_token: &str,
        managed_worker_id: &str,
    ) -> Result<TaskBoardItem, CliError>;

    async fn begin_task_board_dispatch_compensation(
        &self,
        intent_id: &str,
        claim_token: &str,
        managed_worker_id: &str,
        reason: &str,
    ) -> Result<(), CliError>;

    async fn task_board_dispatch_is_completed(
        &self,
        applied: &DispatchAppliedTask,
    ) -> Result<bool, CliError>;

    async fn task_board_dispatch_completion_matches(
        &self,
        intent_id: &str,
        execution_id: &str,
        managed_worker_id: &str,
        admission_owner_id: &str,
        side_effect_worker_id: &str,
        require_workflow_evidence: bool,
    ) -> Result<bool, CliError>;

    async fn task_board_dispatch_is_held(
        &self,
        applied: &DispatchAppliedTask,
    ) -> Result<bool, CliError>;

    async fn renew_task_board_dispatch_claim(
        &self,
        intent_id: &str,
        claim_token: &str,
    ) -> Result<(), CliError>;

    async fn fail_task_board_dispatch(
        &self,
        intent_id: &str,
        claim_token: &str,
        consumed_approval_grant_id: Option<&str>,
        reason: &str,
    ) -> Result<(), CliError>;

    async fn finalize_task_board_dispatch_compensation(
        &self,
        intent_id: &str,
        claim_token: &str,
        managed_worker_id: &str,
        reason: &str,
    ) -> Result<(), CliError>;

    async fn reserve_task_board_dispatch(
        &self,
        plan: &DispatchPlan,
        actor: &str,
        project_dir: Option<&str>,
        hold_worker: bool,
    ) -> Result<ReservedTaskBoardDispatch, CliError>;

    async fn attempt_task_board_dispatch_preparation_claim(
        &self,
        intent_id: &str,
    ) -> Result<TaskBoardPreparationClaim, CliError>;

    async fn claim_task_board_dispatch_preparation(
        &self,
        intent_id: &str,
    ) -> Result<Option<ClaimedTaskBoardDispatchPreparation>, CliError>;

    async fn claim_next_task_board_dispatch_preparation(
        &self,
    ) -> Result<Option<ClaimedTaskBoardDispatchPreparation>, CliError>;

    async fn renew_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
    ) -> Result<(), CliError>;

    async fn complete_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        branch: &str,
        worktree: &str,
    ) -> Result<DispatchAppliedTask, CliError>;

    async fn complete_task_board_dispatch_preparation_with_workflow(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        branch: &str,
        worktree: &str,
        read_only_workflow: Option<TaskBoardReadOnlyWorkflowLaunch>,
        write_workflow: Option<Box<TaskBoardWriteWorkflowLaunch>>,
    ) -> Result<DispatchAppliedTask, CliError>;

    async fn release_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        reason: &str,
    ) -> Result<TaskBoardPreparationRelease, CliError>;

    async fn held_task_board_dispatch_summary(
        &self,
    ) -> Result<TaskBoardHeldDispatchSummary, CliError>;

    async fn held_task_board_dispatch(
        &self,
        board_item_id: &str,
    ) -> Result<HeldTaskBoardDispatch, CliError>;

    async fn claim_held_task_board_dispatch(
        &self,
        board_item_id: &str,
    ) -> Result<ClaimedHeldTaskBoardDispatch, CliError>;
}

/// The trait's one and only impl for [`AsyncDaemonDb`]. Every method is a
/// thin, single-line forward into the free function that actually owns the
/// area's query logic, kept in the file the query has always lived in
/// (`admission_lifecycle.rs`, `dispatch_intents.rs`, and so on) so this file
/// stays a pure interface plus wiring, not a 26-method dumping ground.
impl DispatchAdmissionQueries for AsyncDaemonDb {
    async fn release_task_board_admission_for_managed_worker(
        &self,
        managed_worker_id: &str,
    ) -> Result<bool, CliError> {
        super::admission_lifecycle::release_task_board_admission_for_managed_worker(
            self,
            managed_worker_id,
        )
        .await
    }

    async fn validate_task_board_dispatch_admission_start(
        &self,
        intent_id: &str,
        claim_token: &str,
        actual_capability: Option<TaskBoardLaunchCapability>,
        expected_read_only_fence: Option<(i64, u64)>,
    ) -> Result<(), CliError> {
        super::admission_lifecycle::start::validate_task_board_dispatch_admission_start(
            self,
            intent_id,
            claim_token,
            actual_capability,
            expected_read_only_fence,
        )
        .await
    }

    async fn task_board_admission_worker_recoveries(
        &self,
    ) -> Result<Vec<TaskBoardAdmissionWorkerRecovery>, CliError> {
        super::admission_recovery::task_board_admission_worker_recoveries(self).await
    }

    async fn reconcile_missing_task_board_admission_worker(
        &self,
        expected: &TaskBoardAdmissionWorkerRecovery,
        reason: &str,
    ) -> Result<Option<TaskBoardAdmissionMissingRunRecovery>, CliError> {
        super::admission_recovery::reconcile_missing_task_board_admission_worker(
            self, expected, reason,
        )
        .await
    }

    async fn link_and_enqueue_task_board_dispatch(
        &self,
        board_item_id: &str,
        session_id: &str,
        work_item_id: &str,
        lifecycle: &DispatchLifecycle,
    ) -> Result<DispatchAppliedTask, CliError> {
        super::dispatch_intents::link_and_enqueue_task_board_dispatch(
            self,
            board_item_id,
            session_id,
            work_item_id,
            lifecycle,
        )
        .await
    }

    async fn claim_task_board_dispatch(
        &self,
        board_item_id: &str,
    ) -> Result<Option<ClaimedTaskBoardDispatch>, CliError> {
        super::dispatch_intents::claim_task_board_dispatch(self, board_item_id).await
    }

    async fn claim_next_task_board_dispatch(
        &self,
    ) -> Result<Option<ClaimedTaskBoardDispatch>, CliError> {
        super::dispatch_intents::claim_next_task_board_dispatch(self).await
    }

    async fn complete_task_board_dispatch(
        &self,
        intent_id: &str,
        claim_token: &str,
        managed_worker_id: &str,
    ) -> Result<TaskBoardItem, CliError> {
        super::dispatch_intents::complete_task_board_dispatch(
            self,
            intent_id,
            claim_token,
            managed_worker_id,
        )
        .await
    }

    async fn begin_task_board_dispatch_compensation(
        &self,
        intent_id: &str,
        claim_token: &str,
        managed_worker_id: &str,
        reason: &str,
    ) -> Result<(), CliError> {
        super::dispatch_intents::helpers::begin_task_board_dispatch_compensation(
            self,
            intent_id,
            claim_token,
            managed_worker_id,
            reason,
        )
        .await
    }

    async fn task_board_dispatch_is_completed(
        &self,
        applied: &DispatchAppliedTask,
    ) -> Result<bool, CliError> {
        super::dispatch_intents::helpers::queries::task_board_dispatch_is_completed(self, applied)
            .await
    }

    async fn task_board_dispatch_completion_matches(
        &self,
        intent_id: &str,
        execution_id: &str,
        managed_worker_id: &str,
        admission_owner_id: &str,
        side_effect_worker_id: &str,
        require_workflow_evidence: bool,
    ) -> Result<bool, CliError> {
        super::dispatch_intents::helpers::queries::task_board_dispatch_completion_matches(
            self,
            intent_id,
            execution_id,
            managed_worker_id,
            admission_owner_id,
            side_effect_worker_id,
            require_workflow_evidence,
        )
        .await
    }

    async fn task_board_dispatch_is_held(
        &self,
        applied: &DispatchAppliedTask,
    ) -> Result<bool, CliError> {
        super::dispatch_intents::helpers::queries::task_board_dispatch_is_held(self, applied).await
    }

    async fn renew_task_board_dispatch_claim(
        &self,
        intent_id: &str,
        claim_token: &str,
    ) -> Result<(), CliError> {
        super::dispatch_intents::helpers::queries::renew_task_board_dispatch_claim(
            self,
            intent_id,
            claim_token,
        )
        .await
    }

    async fn fail_task_board_dispatch(
        &self,
        intent_id: &str,
        claim_token: &str,
        consumed_approval_grant_id: Option<&str>,
        reason: &str,
    ) -> Result<(), CliError> {
        super::dispatch_intents::helpers::queries::fail_task_board_dispatch(
            self,
            intent_id,
            claim_token,
            consumed_approval_grant_id,
            reason,
        )
        .await
    }

    async fn finalize_task_board_dispatch_compensation(
        &self,
        intent_id: &str,
        claim_token: &str,
        managed_worker_id: &str,
        reason: &str,
    ) -> Result<(), CliError> {
        super::dispatch_intents::helpers::queries::finalize_task_board_dispatch_compensation(
            self,
            intent_id,
            claim_token,
            managed_worker_id,
            reason,
        )
        .await
    }

    async fn reserve_task_board_dispatch(
        &self,
        plan: &DispatchPlan,
        actor: &str,
        project_dir: Option<&str>,
        hold_worker: bool,
    ) -> Result<ReservedTaskBoardDispatch, CliError> {
        super::dispatch_preparations::reserve_task_board_dispatch(
            self,
            plan,
            actor,
            project_dir,
            hold_worker,
        )
        .await
    }

    async fn attempt_task_board_dispatch_preparation_claim(
        &self,
        intent_id: &str,
    ) -> Result<TaskBoardPreparationClaim, CliError> {
        super::dispatch_preparations::queries::attempt_task_board_dispatch_preparation_claim(
            self, intent_id,
        )
        .await
    }

    async fn claim_task_board_dispatch_preparation(
        &self,
        intent_id: &str,
    ) -> Result<Option<ClaimedTaskBoardDispatchPreparation>, CliError> {
        super::dispatch_preparations::queries::claim_task_board_dispatch_preparation(
            self, intent_id,
        )
        .await
    }

    async fn claim_next_task_board_dispatch_preparation(
        &self,
    ) -> Result<Option<ClaimedTaskBoardDispatchPreparation>, CliError> {
        super::dispatch_preparations::queries::claim_next_task_board_dispatch_preparation(self)
            .await
    }

    async fn renew_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
    ) -> Result<(), CliError> {
        super::dispatch_preparations::queries::renew_task_board_dispatch_preparation(self, claim)
            .await
    }

    async fn complete_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        branch: &str,
        worktree: &str,
    ) -> Result<DispatchAppliedTask, CliError> {
        super::dispatch_preparations::queries::complete_task_board_dispatch_preparation(
            self, claim, branch, worktree,
        )
        .await
    }

    async fn complete_task_board_dispatch_preparation_with_workflow(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        branch: &str,
        worktree: &str,
        read_only_workflow: Option<TaskBoardReadOnlyWorkflowLaunch>,
        write_workflow: Option<Box<TaskBoardWriteWorkflowLaunch>>,
    ) -> Result<DispatchAppliedTask, CliError> {
        super::dispatch_preparations::queries::complete_task_board_dispatch_preparation_with_workflow(
            self,
            claim,
            branch,
            worktree,
            read_only_workflow,
            write_workflow,
        )
        .await
    }

    async fn release_task_board_dispatch_preparation(
        &self,
        claim: &ClaimedTaskBoardDispatchPreparation,
        reason: &str,
    ) -> Result<TaskBoardPreparationRelease, CliError> {
        super::dispatch_preparations::queries::release_task_board_dispatch_preparation(
            self, claim, reason,
        )
        .await
    }

    async fn held_task_board_dispatch_summary(
        &self,
    ) -> Result<TaskBoardHeldDispatchSummary, CliError> {
        super::held_dispatch::queries::held_task_board_dispatch_summary(self).await
    }

    async fn held_task_board_dispatch(
        &self,
        board_item_id: &str,
    ) -> Result<HeldTaskBoardDispatch, CliError> {
        super::held_dispatch::queries::held_task_board_dispatch(self, board_item_id).await
    }

    async fn claim_held_task_board_dispatch(
        &self,
        board_item_id: &str,
    ) -> Result<ClaimedHeldTaskBoardDispatch, CliError> {
        super::held_dispatch::queries::claim_held_task_board_dispatch(self, board_item_id).await
    }
}
