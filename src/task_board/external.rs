// Deliberate public API facade, not scaffolding: `ExternalTask`,
// `ExternalProvider`, `ExternalSyncClient`, the `capabilities`/`config`/
// `create_recovery`/`targeting` foundation, and the whole `github` client
// cluster moved into `harness_task_board::external`. This glob restores them
// for `sync`/`scopes` (still here) and every outside caller that reaches
// `crate::task_board::external::*`, the same way root's own `task_board/
// mod.rs` already restores the earlier-extracted domain through its own
// `pub use harness_task_board::*;`.
pub use harness_task_board::external::*;

mod scopes;
mod sync;

pub(crate) use scopes::{
    ExternalProviderScopeAttempt, ExternalProviderScopeAttemptDecision,
    ExternalProviderScopeAvailability, ExternalProviderScopeHealth, ExternalProviderScopeIdentity,
    ExternalProviderScopeState, ExternalSyncBatch, ExternalSyncScopeOutcome,
};
#[cfg(test)]
pub(crate) use sync::sync_external_tasks_scoped;
pub use sync::{
    ExternalSyncAction, ExternalSyncDirection, ExternalSyncOperation, ExternalSyncOptions,
    configured_sync_clients,
};
pub(crate) use sync::{
    TaskBoardExternalCreateStore, TaskBoardSyncCoordinatorFence,
    TaskBoardSyncCoordinatorFenceDecision, TaskBoardSyncItemSnapshot, TaskBoardSyncStore,
    assign_external_create_recovery, blocked_external_create_follow_ups,
    blocked_external_create_recovery, configured_sync_clients_without_review_requests,
    load_external_create_recovery_work, prepare_external_create_recovery, sync_external_tasks,
    sync_external_tasks_scoped_with_recovery,
};

#[cfg(test)]
mod sync_tests;
#[cfg(test)]
mod tests;
