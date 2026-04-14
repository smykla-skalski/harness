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

pub(crate) use files::list_known_session_ids;
pub(crate) use journal::{
    append_log_entry, append_task_checkpoint, load_log_entries, load_task_checkpoints,
};
pub(crate) use registry::{
    deregister_active, load_active_registry_for, load_project_origin, record_project_origin,
    register_active, ActiveRegistry, ProjectOriginRecord,
};
pub(crate) use state_store::{create_state, load_state, update_state, update_state_if_changed};
