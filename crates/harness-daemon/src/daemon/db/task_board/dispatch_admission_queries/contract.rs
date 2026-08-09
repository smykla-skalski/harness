use super::{
    ClaimedHeldTaskBoardDispatch, ClaimedTaskBoardDispatch, ClaimedTaskBoardDispatchPreparation,
    CliError, DispatchAppliedTask, DispatchLifecycle, DispatchPlan, HeldTaskBoardDispatch,
    ReservedTaskBoardDispatch, TaskBoardAdmissionMissingRunRecovery,
    TaskBoardAdmissionWorkerRecovery, TaskBoardHeldDispatchSummary, TaskBoardItem,
    TaskBoardLaunchCapability, TaskBoardPreparationClaim, TaskBoardPreparationRelease,
    TaskBoardReadOnlyWorkflowLaunch, TaskBoardWriteWorkflowLaunch,
};

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

    async fn migrate_legacy_task_board_admission_worker_owners(&self) -> Result<usize, CliError>;

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
