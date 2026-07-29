//! Core task-board data model: item types, the query/pagination layer, lane
//! ordering, the built-in policy gate, git-identity defaults, runtime
//! configuration wire types, progress rollups, and the legacy file-backed
//! store/machine-registry test doubles, plus the triage, prompt/worker-prompt,
//! project, working-copy, policy-graph, policy-runtime, external-sync/github,
//! automation, dispatch/evaluation/planning, the standalone `github`
//! REST/GraphQL automation-client clusters, and the orchestrator/summary/
//! legacy-import cluster that ties them together.
//!
//! This is a later slice of the `task_board` extraction, following slice 4's
//! triage/prompt/project/working-copy cluster, the slice that added
//! `external`: the sync-domain foundation (`ExternalTask`, `ExternalProvider`,
//! `ExternalSyncClient`, and the `capabilities`/`config`/`create_recovery`/
//! `targeting` support it needs) plus the `github` provider-client cluster
//! that implements that foundation, and slice 7, which added `policy_graph`
//! and landed before this one because this slice's `policy_runtime` depends
//! on it. `external::sync`, `external::scopes`, and the `sync_tests`/`tests`
//! test-only clusters stay in root's own `src/task_board/external.rs` until
//! a follow-up slice moves them; that file's doc comment covers the
//! reverse-dependency shape this split creates.
//!
//! This slice also adds `automation`. `automation` reaches forward into one
//! root module that has not moved yet: `orchestrator::types`'s
//! `TaskBoardOrchestratorWorkflow` enum, which comes here as
//! `automation::orchestrator_workflow` because the rest of that file also
//! needs `dispatch`/`evaluation`/`summary` (out of scope for this slice). It
//! also moves `github::config`'s automation-settings wire types in full
//! (all eight, as `github_config`), because they and `automation::settings`
//! depend on each other's types; this closes the reverse dependency an
//! earlier slice's doc comment flagged, where two files under the standalone
//! `task_board::github` module (distinct from this crate's
//! `external::github`) needed `automation::TaskBoardRepositoryAutomationConfig`
//! before it was extracted. The remaining domain (`transport`, and the
//! `legacy_import`/`orchestrator`/`summary` files that reach into those)
//! stays in the root crate's `src/task_board` for later slices, and reaches
//! back into this crate only through the root crate's own
//! `pub use harness_task_board::*;` facade.
//!
//! This slice also moves the rest of the standalone `github` module in:
//! `client`, `client_graphql`, `evidence`, `evidence_api`, `publication`,
//! `repository`, and `risk` — the GitHub REST/GraphQL automation client used
//! for branch publication and PR merge policy, not `external::github` (the
//! sync-engine's own GitHub client, already in this crate). `github::config`'s
//! wire types moved earlier as `github_config`, closing the only reverse
//! dependency this cluster had; nothing else in it reaches back into the root
//! crate.
//!
//! This slice moves `dispatch`, `evaluation`, and `planning`: the one
//! `task_board` cluster with a real `session` dependency. Their six forward
//! references (`dispatch_lifecycle.rs`'s `SPAWN_REVIEWER_COMMAND`;
//! `dispatch.rs`'s and `evaluation.rs`'s `TaskSeverity`/`TaskSource`/
//! `ReviewVerdict`/`TaskStatus`/`WorkItem`/`ReviewConsensus`) repoint from
//! `crate::session::` to the new `harness-session` dependency directly, now
//! that session is a real crate. `build_dispatch_plans_with_policy`,
//! `machine_mismatch_plan_with_policy`, `consumed_grant_id`, and
//! `dispatch_policy_from_graph` widen from `pub(crate)` to `pub`, gated the
//! same way `SpawnGateSwitches` already was, so the daemon's `daemon-runtime`
//! dispatch code keeps reaching them across the new crate boundary. The
//! `build_dispatch_plan(s)`/`filter_for_local_machine`/
//! `machine_mismatch_plan_with_policy_root` test-only builders widen their
//! bare `#[cfg(test)]` to `#[cfg(any(test, feature = "test-support"))]` for
//! the same reason `store`/`machines` already needed it: root's own
//! `#[cfg(test)]` call sites (`summary.rs`,
//! `daemon::service::task_board::dispatch`) need them visible when the
//! *root* crate is under test, which this crate's own `cfg(test)` never is.
//!
//! `prompt_config`, `prompt_catalog`, `triage_escalation_prompt`, and
//! `worker_prompt` are unconditionally compiled here rather than gated behind
//! root's `daemon-runtime` feature the way their old `src/task_board/mod.rs`
//! declarations were: none of the four has a daemon-only dependency, and the
//! gate only ever controlled whether root's own facade re-exported them, not
//! whether the module compiled.
//!
//! `policy_runtime` keeps the `daemon-runtime` gate its old declaration
//! carried instead: enabling it would grow every non-daemon consumer's
//! default build by ~3,426 lines for no reason, so this crate defines its
//! own `daemon-runtime` feature (matching `harness-reviews`'s) and
//! `harness-daemon` forwards its own feature of the same name onto it.
//!
//! This is the true final slice: `orchestrator`, `summary`, and
//! `legacy_import`, the three files that reach across every earlier slice
//! (`dispatch`/`evaluation`/`external` for `orchestrator`; `dispatch`/
//! `external`/`project*` for `summary`; `policy_graph`/`policy_runtime` for
//! `legacy_import`) and so had to wait for all of them to land first.
//! `legacy_import` keeps the `daemon-runtime` gate `policy_runtime` already
//! established, since it exists only to feed the one-time file-to-database
//! migration the daemon runs; its `LegacyTaskBoardSnapshot` struct, its
//! fields, and its `load`/`empty`/`counts` methods widen from `pub(crate)`
//! to `pub` so the daemon's migration and import code, still in
//! `src/daemon/`, can keep reaching them across the new crate boundary.
//! `TaskBoardOrchestrator` and `summary`'s `build_audit_summary`/
//! `build_dispatch_summary`/`build_dispatch_summary_with_policy_root` widen
//! their bare `#[cfg(test)]` to `#[cfg(any(test, feature = "test-support"))]`
//! for the same reason `store`/`machines`/`dispatch` already needed it:
//! root's own `#[cfg(test)]` call sites need them visible when the *root*
//! crate is under test. `summary`'s `build_audit_summary_with_policy` stays
//! `pub(crate)`-narrowed from root's own `src/task_board/mod.rs`, matching
//! `external`'s `TaskBoardExternalCreateBegin` cluster, because it was
//! `pub(crate)` in root before the move and nothing outside root's own
//! daemon service code needs it. What remains in root's `src/task_board`
//! after this slice is `external::sync`/`external::scopes` and their
//! test-only clusters, the standalone `transport`/`wire` layers, and
//! `github`'s own root-side facade; `transport` is the one true remaining
//! slice.

#![deny(unsafe_code)]

pub mod automation;
pub mod dispatch;
pub mod evaluation;
pub mod external;
pub mod git_identity_defaults;
pub mod github;
pub mod github_config;
pub mod item_fields;
pub mod item_intent;
pub mod item_query;
pub mod lane;
#[cfg(feature = "daemon-runtime")]
pub mod legacy_import;
pub mod machines;
pub mod orchestrator;
pub mod planning;
pub mod policy;
pub mod policy_graph;
#[cfg(feature = "daemon-runtime")]
pub mod policy_runtime;
pub mod progress_rollup;
pub mod project;
pub mod project_color;
pub mod project_shape;
mod prompt_builtins;
pub mod prompt_catalog;
pub mod prompt_config;
mod prompt_template;
pub mod provider_credentials;
pub mod remote_spki_pin;
#[cfg(feature = "daemon-runtime")]
pub mod remote_wire;
pub mod runtime_config;
pub mod store;
pub mod summary;
pub mod triage;
pub mod triage_escalation;
mod triage_escalation_prompt;
pub mod triage_override;
pub mod triage_rules;
pub mod types;
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
pub use dispatch::{
    SpawnGateSwitches, build_dispatch_plans_with_policy, consumed_grant_id,
    dispatch_policy_from_graph, machine_mismatch_plan_with_policy,
};
#[cfg(any(test, feature = "test-support"))]
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
pub use git_identity_defaults::{
    TaskBoardEnvDefaults, TaskBoardGhCliDefaults, TaskBoardGitConfigDefaults,
    TaskBoardGitIdentityDefaults, TaskBoardSshKeyDiscovery,
    discover as discover_git_identity_defaults,
};
pub use github_config::{
    GitHubAutomation, GitHubAutomationLabels, GitHubAutomationSettings, GitHubAutomationToggles,
    GitHubMergeMethod, GitHubProjectConfig, GitHubRequestedReviewers, ProtectedPathRule,
};
pub use item_fields::{
    ExternalRef, ExternalRefProvider, ExternalRefSyncState, PlanningState, TaskUsage,
};
pub use item_query::{
    PreparedTaskBoardItemQuery, TASK_BOARD_LIST_DEFAULT_LIMIT, TASK_BOARD_LIST_MAX_CURSOR_CHARS,
    TASK_BOARD_LIST_MAX_LIMIT, TASK_BOARD_LIST_MAX_QUERY_CHARS, TASK_BOARD_LIST_MAX_TAGS,
    TaskBoardItemQuery, TaskBoardListCursor, TaskBoardListPage, TaskBoardQueryFields,
    TaskBoardQueryTarget, normalize_query_text, select_page, validated_limit,
};
pub use lane::{
    TaskBoardLaneOrigin, sort_task_board_items, validate_lane_placement,
    validate_task_board_lane_order,
};
pub use machines::Machine;
#[cfg(any(test, feature = "test-support"))]
pub use machines::MachineRegistry;
#[cfg(any(test, feature = "test-support"))]
pub use orchestrator::TaskBoardOrchestrator;
pub use orchestrator::{
    TaskBoardGitHubInboxConfig, TaskBoardGitHubProjectConfig, TaskBoardHeldDispatchItem,
    TaskBoardHeldDispatchSummary, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorRunStatus,
    TaskBoardOrchestratorRunSummary, TaskBoardOrchestratorSettings,
    TaskBoardOrchestratorSettingsUpdateRequest, TaskBoardOrchestratorState,
    TaskBoardOrchestratorStatusSnapshot, TaskBoardOrchestratorTickInfo,
    TaskBoardOrchestratorTickPhase, TaskBoardWorkflowExecutionCount,
};
// Thin wire projections of `TaskBoardOrchestratorStatusSnapshot`/`PolicyPipelinePromoteOutcome`,
// named for the boundary they serve rather than the module they live in: the
// daemon's `daemon::protocol::task_board` re-export list names both bare, and
// relies on these exact names to stay free of the task-board/policy-graph
// domain models.
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
    PolicyPipelineNode, PolicyPipelineNodeKind, PolicyPipelinePort, PolicyPipelinePromoteOutcome,
    PolicyPipelinePromoteRequest, PolicyPipelineSaveResponse, PolicyPipelineSimulatedDecision,
    PolicyPipelineSimulationResult, PolicyPipelineValidation, PolicyPipelineValidationCode,
    PolicyPipelineValidationIssue, PolicyScenario, replay::PolicyPipelineReplayDecision,
    replay::PolicyPipelineReplayResult,
};
pub use progress_rollup::{TaskBoardProgressRollup, build_progress_rollups};
pub use prompt_catalog::install_prompt_catalog;
pub use prompt_config::resolve_prompt_catalog_from_env;
pub use provider_credentials::{
    TaskBoardGitHubCredentialSnapshot, TaskBoardOpenRouterCredentialSnapshot,
};
pub use runtime_config::{
    TaskBoardGitHubRepositoryToken, TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitHubTokensSyncResponse, TaskBoardGitRepositoryOverride, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeProfile, TaskBoardGitSigningConfig, TaskBoardGitSigningMode,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOpenRouterTokenSyncResponse,
    normalize_repository_slug,
};
#[cfg(any(test, feature = "test-support"))]
pub use store::TaskBoardStore;
pub use store::default_board_root;
pub use wire::{PolicyPipelinePromoteResponse, TaskBoardOrchestratorStatus};
// Gated to match root's own re-narrowing import in `src/task_board/mod.rs`
// exactly: an unconditional export here would make the glob re-export leak
// this as public API whenever root's narrowing line's condition is false,
// defeating the narrowing.
#[cfg(any(test, feature = "daemon-runtime"))]
pub use summary::build_audit_summary_with_policy;
pub use summary::{
    TaskBoardAuditSummary, TaskBoardMachineSummary, TaskBoardProjectSummary,
    TaskBoardProviderSyncSummary, TaskBoardStatusCount, TaskBoardSyncSummary,
    build_machine_summaries, build_project_summaries, build_sync_summary,
};
#[cfg(any(test, feature = "test-support"))]
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
pub use triage_escalation_prompt::render_triage_escalation_prompt;
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
pub use types::{
    AgentMode, PrIntentSet, TaskBoardItem, TaskBoardPriority, TaskBoardStatus,
    TaskBoardTombstoneCause, TaskBoardWorkflowKind, TaskBoardWorkflowState,
    TaskBoardWorkflowStatus,
};
pub use worker_prompt::{WorkerPromptContext, plan_worker_prompt, render_worker_prompt};
