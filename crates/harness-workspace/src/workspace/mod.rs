pub mod compact;
pub mod ids;
pub mod layout;
pub mod orphan_cleanup;
mod paths;
pub mod project_resolver;
mod remote_kubernetes;
mod session;
pub mod socket_paths;
pub mod worktree;

// Checkout identity is git's, not the workspace's, and `git::identity` is its
// canonical path. These two stay re-exported because every caller reaches them
// while resolving a workspace, not while doing git work; the two types that
// rode along had no caller at all and are gone.
pub use crate::git::identity::{canonical_checkout_root, resolve_git_checkout_identity};
#[cfg(target_os = "macos")]
pub use paths::legacy_macos_root;
pub use paths::{
    HARNESS_PREFIX, NON_INDEXABLE_MARKER_NAME, dirs_home, ensure_non_indexable, harness_data_root,
    shorten_path, utc_now,
};
pub use paths::{account_home_dir, host_home_dir, normalized_env_value};
pub use remote_kubernetes::{
    RemoteKubernetesInstallMemberState, RemoteKubernetesInstallState, cleanup_remote_install_state,
    load_remote_install_state_for_spec, persist_remote_install_state,
    remote_install_state_path_for_spec, sync_gateway_api_install_state,
};
pub use session::{
    current_run_context_path, current_run_context_path_for_project, data_root, project_context_dir,
    project_context_id, session_context_dir, session_context_dir_for_project, session_scope_key,
    suite_root,
};
