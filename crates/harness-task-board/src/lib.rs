//! Core task-board data model: item types, the query/pagination layer, lane
//! ordering, the built-in policy gate, git-identity defaults, runtime
//! configuration wire types, progress rollups, and the legacy file-backed
//! store/machine-registry test doubles, plus the triage, prompt/worker-prompt,
//! project, and working-copy clusters.
//!
//! This is slice 4 of the `task_board` extraction (slice 1 established the
//! crate; this adds `triage*`, `prompt*`/`worker_prompt`, `project`/
//! `project_color`/`project_shape`, and `working_copy`). The remaining
//! domain (`automation`, `dispatch`/`evaluation`/`planning`, `external`,
//! `github`, `policy_graph`, `policy_runtime`, `transport`, and the
//! `legacy_import`/`orchestrator`/`summary` files that reach into those)
//! stays in the root crate's `src/task_board` for later slices, and reaches
//! back into this crate only through the root crate's own
//! `pub use harness_task_board::*;` facade.
//!
//! `prompt_config`, `prompt_catalog`, `triage_escalation_prompt`, and
//! `worker_prompt` are unconditionally compiled here rather than gated behind
//! root's `daemon-runtime` feature the way their old `src/task_board/mod.rs`
//! declarations were: none of the four has a daemon-only dependency, and the
//! gate only ever controlled whether root's own facade re-exported them, not
//! whether the module compiled.

#![deny(unsafe_code)]

pub mod git_identity_defaults;
pub mod item_fields;
pub mod item_query;
pub mod lane;
pub mod machines;
pub mod policy;
pub mod progress_rollup;
pub mod project;
pub mod project_color;
pub mod project_shape;
mod prompt_builtins;
pub mod prompt_catalog;
pub mod prompt_config;
mod prompt_template;
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

pub use git_identity_defaults::{
    TaskBoardEnvDefaults, TaskBoardGhCliDefaults, TaskBoardGitConfigDefaults,
    TaskBoardGitIdentityDefaults, TaskBoardSshKeyDiscovery,
    discover as discover_git_identity_defaults,
};
pub use item_fields::{
    ExternalRef, ExternalRefProvider, ExternalRefSyncState, PlanningState, TaskUsage,
};
pub use item_query::{
    PreparedTaskBoardItemQuery, TASK_BOARD_LIST_DEFAULT_LIMIT,
    TASK_BOARD_LIST_MAX_CURSOR_CHARS, TASK_BOARD_LIST_MAX_LIMIT,
    TASK_BOARD_LIST_MAX_QUERY_CHARS, TASK_BOARD_LIST_MAX_TAGS, TaskBoardItemQuery,
    TaskBoardListCursor, TaskBoardListPage, TaskBoardQueryFields, TaskBoardQueryTarget,
    normalize_query_text, select_page, validated_limit,
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
pub use progress_rollup::{TaskBoardProgressRollup, build_progress_rollups};
pub use prompt_catalog::install_prompt_catalog;
pub use prompt_config::resolve_prompt_catalog_from_env;
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
