pub use harness_workspace::workspace::{
    HARNESS_PREFIX, canonical_checkout_root, compact, data_root, dirs_home, ensure_non_indexable,
    harness_data_root, ids, layout, project_context_dir, resolve_git_checkout_identity,
    session_context_dir, session_scope_key, utc_now,
};
#[cfg(target_os = "macos")]
pub use harness_workspace::workspace::legacy_macos_root;

#[must_use]
pub const fn compact_handoff_version() -> u32 {
    compact::handoff_version()
}
