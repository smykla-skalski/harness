// Deliberate public API facade, not scaffolding: `crate::task_board::types`,
// `item_fields`, `item_query`, `lane`, `policy`, `git_identity_defaults`,
// `progress_rollup`, `remote_spki_pin`, `runtime_config`, `store`, `machines`,
// part of `wire`, `project`/`project_color`/`project_shape`, `triage*`,
// `prompt*`/`worker_prompt`, `working_copy`, `policy_graph`, `automation`,
// and `github::config`'s whole GitHub automation-settings wire-type module
// moved into the standalone `harness-task-board` crate. Every other
// task-board subtree below reaches those through this glob re-export
// exactly the way external callers (`daemon`, `session`, `hooks`) already
// do, so none of them needed an import change for the move.
pub use harness_task_board::*;

pub mod dispatch;
pub mod evaluation;
pub mod external;
mod external_create_intents;
pub mod github;
#[allow(dead_code)]
#[cfg(feature = "daemon-runtime")]
pub(crate) mod legacy_import;
pub mod orchestrator;
pub mod planning;
#[cfg(feature = "daemon-runtime")]
pub mod policy_runtime;
pub mod summary;
pub mod transport;
pub mod wire;

pub use dispatch::{
    DispatchAppliedTask, DispatchBlockReason, DispatchExecutionSummary, DispatchFailure,
    DispatchFailureKind, DispatchPlan, DispatchReadiness, EvaluatorIntent, FollowUpPhase,
    ReviewerIntent, SessionIntent, TaskBoardReadOnlyWorkflowLaunch, TaskBoardWriteWorkflowLaunch,
    TaskCreationIntent, WorkerIntent,
};
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use dispatch::{
    SpawnGateSwitches, build_dispatch_plans_with_policy, consumed_grant_id,
    dispatch_policy_from_graph, machine_mismatch_plan_with_policy,
};
#[cfg(test)]
pub use dispatch::{
    build_dispatch_plan, build_dispatch_plans, build_dispatch_plans_with_policy_root,
    filter_for_local_machine, machine_mismatch_plan_with_policy_root,
};
pub use evaluation::{
    EvaluationSignalFailure, TaskBoardEvaluationDecision, TaskBoardEvaluationOutcome,
    TaskBoardEvaluationRecord, TaskBoardEvaluationSummary, evaluate_task_board_item,
    failed_workflow, missing_session_record, missing_task_record, record_from_decision,
    skipped_unlinked_record,
};
pub use external::{
    ExternalCreateOutcome, ExternalProvider, ExternalProviderCapabilities, ExternalRevisionUpdate,
    ExternalSyncAction, ExternalSyncClient, ExternalSyncConfig, ExternalSyncConflictPolicy,
    ExternalSyncDirection, ExternalSyncField, ExternalSyncOperation, ExternalSyncOptions,
    ExternalTask, ExternalTaskRef, ExternalTaskUpdate, ExternalUpdateOutcome, GH_TOKEN_ENV,
    GITHUB_REPOSITORY_ENV, GitHubInboxSyncClient, GitHubSyncClient, HARNESS_GITHUB_REPOSITORY_ENV,
    HARNESS_GITHUB_TOKEN_ENV, ProviderExclusionAuditContext, ProviderExclusionRestoreOutcome,
    configured_sync_clients,
};
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use external::{
    TaskBoardExternalCreateStore, TaskBoardSyncStore,
    configured_sync_clients_without_review_requests, imported_review_references_from_items,
    reconcile_review_item_from_snapshots, sync_external_tasks,
};
pub(crate) use external_create_intents::{
    TaskBoardExternalCreateBegin, TaskBoardExternalCreateEvidence, TaskBoardExternalCreateExisting,
    TaskBoardExternalCreateFinalizeDisposition, TaskBoardExternalCreateFinalizeResult,
    TaskBoardExternalCreateIntent, TaskBoardExternalCreateIntentState,
    TaskBoardExternalCreateReceipt, TaskBoardExternalCreateSnapshot,
};
#[cfg(test)]
pub use orchestrator::TaskBoardOrchestrator;
pub use orchestrator::{
    TaskBoardGitHubInboxConfig, TaskBoardGitHubProjectConfig, TaskBoardHeldDispatchItem,
    TaskBoardHeldDispatchSummary, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorRunStatus,
    TaskBoardOrchestratorRunSummary, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardOrchestratorState,
    TaskBoardOrchestratorStatus, TaskBoardOrchestratorTickInfo, TaskBoardOrchestratorTickPhase,
    TaskBoardWorkflowExecutionCount,
};
pub use planning::{
    PlanApprovalBlockReason, PlanApprovalGate, PlanningTransition, approval_gate, approve_plan,
    begin_planning, revoke_plan, submit_plan,
};
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use summary::build_audit_summary_with_policy;
pub use summary::{
    TaskBoardAuditSummary, TaskBoardMachineSummary, TaskBoardProjectSummary,
    TaskBoardProviderSyncSummary, TaskBoardStatusCount, TaskBoardSyncSummary,
    build_machine_summaries, build_project_summaries, build_sync_summary,
};
#[cfg(test)]
pub use summary::{
    build_audit_summary, build_dispatch_summary, build_dispatch_summary_with_policy_root,
};
