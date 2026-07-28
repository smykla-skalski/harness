//! Core task-board data model: item types, the query/pagination layer, lane
//! ordering, the built-in policy gate, git-identity defaults, runtime
//! configuration wire types, progress rollups, and the legacy file-backed
//! store/machine-registry test doubles.
//!
//! This is slice 1 of the `task_board` extraction. Most of the domain -
//! `automation`, `dispatch`/`evaluation`/`planning`, `external`, `github`,
//! `policy_graph`, `policy_runtime`, `project`/`project_color`/
//! `project_shape`, `transport`, `triage*`, the `prompt*`/`worker_prompt`
//! cluster, `working_copy`, and the `legacy_import`/`orchestrator`/`summary`
//! files that reach into those - stays in the root crate's `src/task_board`
//! for later slices, and reaches back into this crate only through the root
//! crate's own `pub use harness_task_board::*;` facade.

#![deny(unsafe_code)]

pub mod git_identity_defaults;
pub mod item_fields;
pub mod item_query;
pub mod lane;
pub mod machines;
pub mod policy;
pub mod progress_rollup;
pub mod remote_spki_pin;
pub mod runtime_config;
pub mod store;
pub mod types;
pub mod wire;

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
pub use types::{
    AgentMode, TaskBoardItem, TaskBoardPriority, TaskBoardStatus, TaskBoardTombstoneCause,
    TaskBoardWorkflowKind, TaskBoardWorkflowState, TaskBoardWorkflowStatus,
};
