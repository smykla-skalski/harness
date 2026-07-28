// Deliberate public API facade, not scaffolding: `crate::task_board::types`,
// `item_fields`, `item_query`, `lane`, `policy`, `git_identity_defaults`,
// `progress_rollup`, `remote_spki_pin`, `runtime_config`, `store`, `machines`,
// and part of `wire` moved into the standalone `harness-task-board` crate.
// Every other task-board subtree below reaches those through this glob
// re-export exactly the way external callers (`daemon`, `session`, `hooks`)
// already do, so none of them needed an import change for the move.
pub use harness_task_board::*;

pub mod automation;
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
pub mod policy_graph;
pub mod project;
pub mod project_color;
pub mod project_shape;
#[cfg(feature = "daemon-runtime")]
pub mod policy_runtime;
mod prompt_builtins;
pub(crate) mod prompt_catalog;
#[cfg(feature = "daemon-runtime")]
mod prompt_config;
mod prompt_template;
pub mod summary;
pub mod transport;
pub mod triage;
pub mod triage_escalation;
mod triage_escalation_prompt;
pub mod triage_override;
pub mod triage_rules;
pub mod wire;
mod worker_prompt;
pub mod working_copy;

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
    TaskBoardOrchestratorWorkflow, TaskBoardWorkflowExecutionCount,
};
pub use planning::{
    PlanApprovalBlockReason, PlanApprovalGate, PlanningTransition, approval_gate, approve_plan,
    begin_planning, revoke_plan, submit_plan,
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
pub use triage::{
    BUILTIN_V1_EVALUATOR_IDENTITY, BUILTIN_V1_EVALUATOR_VERSION, OVERRIDE_PLACEMENT_PRODUCER,
    TaskBoardTriageDecision, TaskBoardTriageDecisionRecord, TriageCause, TriageOutcome,
    TriageReasonCode, TriageVerdict, canonicalize_labels, evaluate_builtin_v1,
    evidence_fingerprint, is_canonical_bounded_text, is_canonical_decided_at,
    is_canonical_evaluator_identity, is_canonical_evidence_fingerprint, is_canonical_reason_detail,
    is_exclusion_label, matched_exclusion_label,
};
pub use triage_escalation::{
    AGENT_V1_EVALUATOR_IDENTITY, AGENT_V1_EVALUATOR_VERSION, TaskBoardTriageEscalationConfig,
    TaskBoardTriageEscalationRejectReason, TaskBoardTriageEscalationStatus,
    TaskBoardTriageEscalationVerdictOutcome,
};
pub use triage_override::{
    TaskBoardTriageEffectiveOutcome, TaskBoardTriageEffectiveSource, TaskBoardTriageOverride,
    effective_triage_outcome, is_canonical_override_actor, is_canonical_override_reason,
    suppress_placement_for_override,
};
pub use triage_rules::{
    MAX_CONDITIONS_PER_RULE, MAX_LABEL_CONDITION_ITEMS, MAX_RULE_ID_BYTES,
    MAX_STRING_CONDITION_BYTES, MAX_TRIAGE_RULES, RUNTIME_RULES_EVALUATOR_IDENTITY,
    TRIAGE_RULE_SET_SCHEMA_VERSION, TriagePriorityAction, TriageRule, TriageRuleCondition,
    TriageRuleEvaluation, TriageRuleMatch, TriageRuleOutcome, TriageRuleSetActivationResult,
    TriageRuleSetAuditEntry, TriageRuleSetAuditKind, TriageRuleSetDraft,
    TriageRuleSetDraftSaveResult, TriageRuleSetPreviewDiffEntry, TriageRuleSetPreviewResult,
    TriageRuleSetRevisionStatus, TriageRuleSetRevisionSummary, TriageRuleSetV1,
    TriageRuleSetValidationIssue, TriageRuleSetValidationReport, evaluate_triage_rule_set,
    is_canonical_rule_id, validate_triage_rule_set,
};
#[cfg(feature = "daemon-runtime")]
pub(crate) use prompt_catalog::install_prompt_catalog;
#[cfg(feature = "daemon-runtime")]
pub(crate) use prompt_config::resolve_prompt_catalog_from_env;
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use triage_escalation_prompt::render_triage_escalation_prompt;
pub(crate) use worker_prompt::plan_worker_prompt;
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use worker_prompt::{WorkerPromptContext, render_worker_prompt};
