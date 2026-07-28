mod files;
mod journal;
pub mod migrations;
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

// This module's whole surface is `pub` rather than `pub(crate)`: the root
// crate's `session::service`, `session::observe`, and `daemon::db` reach
// into it broadly, and they stay in the root crate as separate, larger
// extractions.
pub use files::{
    is_valid_session_id, layout_candidates_from_context_root, layout_candidates_from_project_dir,
    layout_from_project_dir, list_known_session_ids, list_known_session_ids_from_context_root,
    validate_new_session_id, validate_session_id,
};
pub use journal::{
    append_log_entry, append_review, append_task_checkpoint, load_log_entries, load_reviews,
    load_task_checkpoints,
};
pub use registry::{
    ActiveRegistry, ProjectOriginRecord, deregister_active, load_active_registry_for,
    load_active_registry_for_context_root, load_project_origin, record_adopted_session_root,
    record_project_origin, register_active,
};
pub use state_store::{
    create_state, load_state, save_state, update_state, update_state_if_changed,
};
