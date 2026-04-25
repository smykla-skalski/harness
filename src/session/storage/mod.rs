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

pub use files::layout_from_project_dir;
pub(crate) use files::{
    layout_candidates_from_context_root, layout_candidates_from_project_dir,
    list_known_session_ids, list_known_session_ids_from_context_root,
};
pub(crate) use journal::{
    append_log_entry, append_task_checkpoint, load_log_entries, load_task_checkpoints,
};
pub(crate) use journal::{append_review, load_reviews};
pub(crate) use registry::{
    ActiveRegistry, ProjectOriginRecord, deregister_active, load_active_registry_for,
    load_active_registry_for_context_root, load_project_origin, record_adopted_session_root,
    record_project_origin, register_active,
};
pub(crate) use state_store::{
    create_state, load_state, save_state, update_state, update_state_if_changed,
};
