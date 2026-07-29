//! `harness-daemon`'s own view of the task-board domain: everything the
//! daemon's service/db/http code needs, minus the CLI-facing `transport`
//! surface, which dials the daemon directly and must never be part of the
//! daemon's own build. Hand-written, like `session.rs`, rather than
//! `#[path]`-including root's `src/task_board/mod.rs`, so declaring
//! `pub mod transport;` here is exactly the mistake this file exists to make
//! impossible. Unlike `session.rs`'s enumerated per-submodule list, this
//! file leads with a glob: `harness_task_board`'s own crate root already
//! re-exports almost everything root's facade used to shadow, so curating
//! that list a second time here would just restate it.
pub use harness_task_board::*;

// `harness_task_board::external`'s items aren't re-exported flat at that
// crate's own root, only through its `external` module, so daemon code that
// reaches `crate::task_board::ExternalProvider` (flat, matching root's own
// `src/task_board/mod.rs` re-export) needs this list restated here too.
pub use harness_task_board::external::{
    ExternalCreateOutcome, ExternalProvider, ExternalProviderCapabilities, ExternalRevisionUpdate,
    ExternalSyncAction, ExternalSyncClient, ExternalSyncConfig, ExternalSyncConflictPolicy,
    ExternalSyncDirection, ExternalSyncField, ExternalSyncOperation, ExternalSyncOptions,
    ExternalTask, ExternalTaskRef, ExternalTaskUpdate, ExternalUpdateOutcome, GH_TOKEN_ENV,
    GITHUB_REPOSITORY_ENV, GitHubInboxSyncClient, GitHubSyncClient, HARNESS_GITHUB_REPOSITORY_ENV,
    HARNESS_GITHUB_TOKEN_ENV, ProviderExclusionAuditContext, ProviderExclusionRestoreOutcome,
    configured_sync_clients,
};

// Same narrowing root's own `src/task_board/mod.rs` applies: these stay
// `pub(crate)` here rather than the wider visibility the crate grants,
// because nothing outside the daemon's own service code needs them.
pub(crate) use harness_task_board::external::{
    TaskBoardExternalCreateBegin, TaskBoardExternalCreateEvidence, TaskBoardExternalCreateExisting,
    TaskBoardExternalCreateFinalizeDisposition, TaskBoardExternalCreateFinalizeResult,
    TaskBoardExternalCreateIntent, TaskBoardExternalCreateIntentState,
    TaskBoardExternalCreateReceipt, TaskBoardExternalCreateSnapshot,
};
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use harness_task_board::external::{
    TaskBoardExternalCreateStore, TaskBoardSyncStore,
    configured_sync_clients_without_review_requests, imported_review_references_from_items,
    reconcile_review_item_from_snapshots, sync_external_tasks,
};
// Shadows the wider glob re-export above for the same reason root's own
// `src/task_board/mod.rs` shadows it: `build_audit_summary_with_policy` was
// `pub(crate)` before the move, and only the daemon's own service code needs
// it.
#[cfg(any(test, feature = "daemon-runtime"))]
#[expect(
    hidden_glob_reexports,
    reason = "deliberately narrows this one item back to pub(crate) against the glob above"
)]
pub(crate) use harness_task_board::build_audit_summary_with_policy;
