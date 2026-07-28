//! Core task-board data model: item types, the query/pagination layer, lane
//! ordering, the built-in policy gate, git-identity defaults, runtime
//! configuration wire types, progress rollups, and the legacy file-backed
//! store/machine-registry test doubles, plus the triage, prompt/worker-prompt,
//! project, working-copy, policy-graph, policy-runtime, external-sync/github,
//! and automation clusters.
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
//! before it was extracted. The remaining domain (`dispatch`/`evaluation`/
//! `planning`, `external`, the rest of `github` (`client`/`client_graphql`/
//! `evidence`/`evidence_api`/`publication`/`repository`/`risk`), `transport`,
//! and the `legacy_import`/`orchestrator`/`summary` files that reach into
//! those) stays in the root crate's `src/task_board` for later slices, and
//! reaches back into this crate only through the root crate's own
//! `pub use harness_task_board::*;` facade.
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

#![deny(unsafe_code)]

pub mod automation;
pub mod external;
pub mod git_identity_defaults;
pub mod github_config;
pub mod item_fields;
pub mod item_query;
pub mod lane;
pub mod machines;
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
pub mod runtime_config;
pub mod store;
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
    AgentMode, TaskBoardItem, TaskBoardPriority, TaskBoardStatus, TaskBoardTombstoneCause,
    TaskBoardWorkflowKind, TaskBoardWorkflowState, TaskBoardWorkflowStatus,
};
pub use worker_prompt::{WorkerPromptContext, plan_worker_prompt, render_worker_prompt};
