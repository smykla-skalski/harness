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
// These are unused until Task 8+9 migrate callers; allow to avoid spurious warnings.
#[allow(unused_imports)]
pub(crate) use files::{list_known_session_ids_for_layout, list_session_ids_in_project_dir};
#[allow(unused_imports)]
pub(crate) use journal::{
    append_log_entry, append_task_checkpoint, load_log_entries, load_task_checkpoints,
};
#[allow(unused_imports)]
pub(crate) use registry::{
    ActiveRegistry, ProjectOriginRecord, deregister_active, load_active_registry_for_layout,
    load_project_origin, record_project_origin, register_active,
};
#[allow(unused_imports)]
pub(crate) use state_store::{create_state, load_state, update_state, update_state_if_changed};

// Legacy adapters (TODO(b-task-8): remove after cascade migration)
pub(crate) use files::list_known_session_ids;
pub(crate) use journal::{
    append_log_entry_legacy, append_task_checkpoint_legacy, load_log_entries_legacy,
    load_task_checkpoints_legacy,
};
pub(crate) use registry::{deregister_active_legacy, load_active_registry_for, register_active_legacy};
pub(crate) use state_store::{
    create_state_legacy, load_state_legacy, update_state_if_changed_legacy, update_state_legacy,
};
