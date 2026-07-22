pub mod automation;
pub mod dispatch;
pub mod evaluation;
pub mod external;
mod external_create_intents;
pub mod git_identity_defaults;
pub mod github;
#[allow(dead_code)]
#[cfg(feature = "daemon-runtime")]
pub(crate) mod legacy_import;
pub mod machines;
pub mod orchestrator;
pub mod planning;
pub mod policy;
pub mod policy_graph;
#[cfg(feature = "daemon-runtime")]
pub mod policy_runtime;
pub mod progress_rollup;
pub(crate) mod remote_spki_pin;
pub mod runtime_config;
pub mod store;
pub mod summary;
pub mod transport;
pub mod types;
mod worker_prompt;

pub use automation::*;
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
    HARNESS_GITHUB_TOKEN_ENV, HARNESS_TODOIST_TOKEN_ENV, TodoistSyncClient,
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
pub use git_identity_defaults::{
    TaskBoardEnvDefaults, TaskBoardGhCliDefaults, TaskBoardGitConfigDefaults,
    TaskBoardGitIdentityDefaults, TaskBoardSshKeyDiscovery,
    discover as discover_git_identity_defaults,
};
pub use machines::Machine;
#[cfg(test)]
pub use machines::MachineRegistry;
#[cfg(test)]
pub use orchestrator::TaskBoardOrchestrator;
pub use orchestrator::{
    TaskBoardGitHubInboxConfig, TaskBoardGitHubProjectConfig, TaskBoardHeldDispatchItem,
    TaskBoardHeldDispatchSummary, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorRunStatus,
    TaskBoardOrchestratorRunSummary, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardOrchestratorState,
    TaskBoardOrchestratorStatus, TaskBoardOrchestratorTickInfo, TaskBoardOrchestratorTickPhase,
    TaskBoardOrchestratorWorkflow, TaskBoardTodoistInboxConfig, TaskBoardWorkflowExecutionCount,
};
pub use planning::{
    PlanApprovalBlockReason, PlanApprovalGate, PlanningTransition, approval_gate, approve_plan,
    begin_planning, revoke_plan, submit_plan,
};
pub use policy::{
    BuiltInPolicyGate, PolicyAction, PolicyApprovalGrant, PolicyApprovalGrantState,
    PolicyApprovalState, PolicyDecision, PolicyEvidence, PolicyGate, PolicyInput, PolicyReasonCode,
    PolicySubject,
};
pub use policy_graph::{
    GraphPolicyGate, POLICY_GRAPH_INITIAL_REVISION, POLICY_GRAPH_SCHEMA_VERSION, PolicyCanvasPoint,
    PolicyCanvasRect, PolicyEvidenceCheck, PolicyEvidenceField, PolicyEvidencePredicate,
    PolicyGraph, PolicyGraphDecision, PolicyGraphEdge, PolicyGraphEdgeCondition, PolicyGraphGroup,
    PolicyGraphLayout, PolicyGraphMode, PolicyGraphNode, PolicyGraphNodeKind,
    PolicyGraphNodeLayout, PolicyGraphPortDirection, PolicyGraphSimulation,
    PolicyGraphValidationIssue, PolicyGraphValidationReport, PolicyPipelineAuditSummary,
    PolicyPipelineDocument, PolicyPipelineEdge, PolicyPipelineGoLiveDiff,
    PolicyPipelineGoLiveDiffEntry, PolicyPipelineGroup, PolicyPipelineLayout,
    PolicyPipelineMakeLiveRequest, PolicyPipelineMakeLiveResponse, PolicyPipelineMode,
    PolicyPipelineNode, PolicyPipelineNodeKind, PolicyPipelinePort, PolicyPipelinePromoteRequest,
    PolicyPipelinePromoteResponse, PolicyPipelineSaveResponse, PolicyPipelineSimulatedDecision,
    PolicyPipelineSimulationResult, PolicyPipelineValidation, PolicyPipelineValidationCode,
    PolicyPipelineValidationIssue, PolicyScenario, replay::PolicyPipelineReplayDecision,
    replay::PolicyPipelineReplayResult,
};
pub use progress_rollup::{TaskBoardProgressRollup, build_progress_rollups};
pub use runtime_config::{
    TaskBoardGitHubRepositoryToken, TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitHubTokensSyncResponse, TaskBoardGitRepositoryOverride, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeProfile, TaskBoardGitSigningConfig, TaskBoardGitSigningMode,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOpenRouterTokenSyncResponse,
    TaskBoardTodoistTokenSyncRequest, TaskBoardTodoistTokenSyncResponse, normalize_repository_slug,
};
#[cfg(test)]
pub use store::TaskBoardStore;
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use store::default_board_root;
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
pub use types::{
    AgentMode, ExternalRef, ExternalRefProvider, ExternalRefSyncState, PlanningState,
    TaskBoardItem, TaskBoardPriority, TaskBoardStatus, TaskBoardWorkflowState,
    TaskBoardWorkflowStatus, TaskUsage,
};
pub(crate) use worker_prompt::plan_worker_prompt;
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use worker_prompt::{WorkerPromptContext, render_worker_prompt};
