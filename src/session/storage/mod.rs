mod files;
mod journal;
mod migrations;
mod registry;
mod state_store;

#[cfg(test)]
mod journal_tests;
#[cfg(test)]
mod migration_tests;
#[cfg(test)]
mod registry_tests;
#[cfg(test)]
mod state_tests;
#[cfg(test)]
mod test_support;

// New SessionLayout-based API
#[expect(
    unused_imports,
    reason = "consumed after b-task-8 cascade"
)]
pub(crate) use files::{list_known_session_ids_for_layout, list_session_ids_in_project_dir};
#[expect(
    unused_imports,
    reason = "consumed after b-task-8 cascade"
)]
pub(crate) use journal::{append_log_entry, append_task_checkpoint, load_log_entries, load_task_checkpoints};
pub(crate) use registry::{ActiveRegistry, ProjectOriginRecord, load_project_origin, record_project_origin};
#[expect(
    unused_imports,
    reason = "consumed after b-task-8 cascade"
)]
pub(crate) use registry::{deregister_active, load_active_registry_for_layout, register_active};
#[expect(
    unused_imports,
    reason = "consumed after b-task-8 cascade"
)]
pub(crate) use state_store::{create_state, load_state, update_state, update_state_if_changed};

// Legacy adapters (TODO(b-task-8): remove after cascade migration)
pub(crate) use files::list_known_session_ids;
// TODO(b-task-9): drop this re-export once every caller takes a SessionLayout.
pub use files::layout_from_project_dir;
pub(crate) use journal::{
    append_log_entry_legacy, append_task_checkpoint_legacy, load_log_entries_legacy,
    load_task_checkpoints_legacy,
};
pub(crate) use registry::{deregister_active_legacy, load_active_registry_for, register_active_legacy};
pub(crate) use state_store::{
    create_state_legacy, load_state_legacy, update_state_if_changed_legacy, update_state_legacy,
};
