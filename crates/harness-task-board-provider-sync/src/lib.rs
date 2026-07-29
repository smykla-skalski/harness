//! Task-board's external-provider sync: scope-attempt fencing/backoff,
//! sync-conflict bookkeeping, and external-create intent tracking. Extracted
//! from `harness-daemon`'s `db/task_board` -- the one area of that seam that
//! reaches into nothing but the shared item-lifecycle core, so it can build
//! on its own without dragging any sibling area with it.
//!
//! `harness-daemon` depends on this crate, not the other way around: see
//! `store.rs` for how this crate reaches the daemon's storage primitives
//! and the item-lifecycle core without a dependency back onto
//! `harness-daemon` itself.
//!
//! `provider_exclusion`'s hide/restore family did not move here. Unlike
//! everything in this crate, it calls directly into `triage_apply`,
//! `triage_apply_rules`, `triage_audit`, `triage_escalation_enqueue`,
//! `lane_order`, and `dispatch_intents` -- other seam areas this extraction
//! left in place, not the item-lifecycle core. It stays in
//! `daemon/db/task_board/provider_exclusion.rs` until one of those areas
//! gets a boundary of its own.

mod mapper;
mod provider_external_create_evidence;
mod provider_external_create_finalize;
mod provider_external_create_follow_up;
mod provider_external_create_rows;
mod provider_external_creates;
mod provider_sync;
mod provider_sync_conflicts;
mod store;
mod support;

pub use provider_external_create_finalize::finalize_task_board_external_create_intent;
pub use provider_external_create_follow_up::complete_task_board_external_create_follow_ups;
pub use provider_external_creates::{
    begin_task_board_external_create_intent, list_created_task_board_external_create_intents,
    list_in_flight_task_board_external_create_intents,
    list_pending_task_board_external_create_follow_ups,
    list_pending_task_board_external_create_intents, record_task_board_external_create_outcome,
    task_board_external_create_intent, task_board_external_create_intent_by_create_key,
    task_board_external_create_receipt,
};
pub use provider_sync::{
    begin_task_board_provider_scope_attempt, complete_task_board_provider_scope_failure,
    complete_task_board_provider_scope_success, release_task_board_provider_scope_attempt,
    renew_task_board_provider_scope_attempt, task_board_provider_scope_state,
};
#[cfg(any(test, feature = "daemon-runtime"))]
pub use provider_sync_conflicts::open_task_board_sync_conflicts;
pub use provider_sync_conflicts::{
    SyncConflictReplacement, replace_open_sync_conflicts_in_connection,
    replace_open_task_board_sync_conflicts, supersede_open_task_board_sync_conflicts,
};
pub use store::ProviderSyncStore;
