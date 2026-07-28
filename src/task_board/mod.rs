// Deliberate public API facade, not scaffolding: `crate::task_board::types`,
// `item_fields`, `item_query`, `lane`, `policy`, `git_identity_defaults`,
// `progress_rollup`, `remote_spki_pin`, `runtime_config`, `store`, `machines`,
// part of `wire`, `project`/`project_color`/`project_shape`, `triage*`,
// `prompt*`/`worker_prompt`, `working_copy`, `policy_graph`, `policy_runtime`,
// `automation`, `dispatch`/`evaluation`/`planning`, `github::config`'s whole
// GitHub automation-settings wire-type module, and now
// `orchestrator`/`summary`/`legacy_import` moved into the standalone
// `harness-task-board` crate. Every other task-board subtree below reaches
// those through this glob re-export exactly the way external callers
// (`daemon`, `session`, `hooks`) already do, so none of them needed an
// import change for the move.
pub use harness_task_board::*;

pub mod external;
pub mod github;
pub mod transport;
pub mod wire;

pub use external::{
    ExternalCreateOutcome, ExternalProvider, ExternalProviderCapabilities, ExternalRevisionUpdate,
    ExternalSyncAction, ExternalSyncClient, ExternalSyncConfig, ExternalSyncConflictPolicy,
    ExternalSyncDirection, ExternalSyncField, ExternalSyncOperation, ExternalSyncOptions,
    ExternalTask, ExternalTaskRef, ExternalTaskUpdate, ExternalUpdateOutcome, GH_TOKEN_ENV,
    GITHUB_REPOSITORY_ENV, GitHubInboxSyncClient, GitHubSyncClient, HARNESS_GITHUB_REPOSITORY_ENV,
    HARNESS_GITHUB_TOKEN_ENV, ProviderExclusionAuditContext, ProviderExclusionRestoreOutcome,
    configured_sync_clients,
};
pub(crate) use external::{
    TaskBoardExternalCreateBegin, TaskBoardExternalCreateEvidence, TaskBoardExternalCreateExisting,
    TaskBoardExternalCreateFinalizeDisposition, TaskBoardExternalCreateFinalizeResult,
    TaskBoardExternalCreateIntent, TaskBoardExternalCreateIntentState,
    TaskBoardExternalCreateReceipt, TaskBoardExternalCreateSnapshot,
};
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use external::{
    TaskBoardExternalCreateStore, TaskBoardSyncStore,
    configured_sync_clients_without_review_requests, imported_review_references_from_items,
    reconcile_review_item_from_snapshots, sync_external_tasks,
};
// `summary::build_audit_summary_with_policy` was `pub(crate)` in this file
// before the move and stays that way: nothing outside root's own daemon
// service code (`daemon::service::task_board_db`,
// `daemon::service::task_board_orchestrator_db`) needs it, so this explicit
// import shadows the wider visibility the crate needs to grant for the
// re-export itself to compile, the same way `external`'s
// `TaskBoardExternalCreateBegin` cluster above does. Unlike that cluster,
// this one imports directly from `harness_task_board` rather than through a
// root-local facade submodule (`orchestrator`/`summary`/`legacy_import` have
// none left after this move), so the shadowing is against the same crate the
// glob above already pulls from, and rustc's `hidden_glob_reexports` flags
// exactly that as an expected, not accidental, shadow.
#[cfg(any(test, feature = "daemon-runtime"))]
#[expect(
    hidden_glob_reexports,
    reason = "deliberately narrows this one item back to pub(crate) against the glob above"
)]
pub(crate) use harness_task_board::build_audit_summary_with_policy;
