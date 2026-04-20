pub mod compact;
pub mod ids;
mod git;
mod paths;
pub mod project_resolver;
mod remote_kubernetes;
mod session;
pub mod socket_paths;

pub use git::{
    GitCheckoutIdentity, GitCheckoutKind, canonical_checkout_root, resolve_git_checkout_identity,
};
pub use paths::{HARNESS_PREFIX, dirs_home, harness_data_root, shorten_path, utc_now};
#[cfg(target_os = "macos")]
pub use paths::legacy_macos_root;
pub(crate) use paths::{host_home_dir, normalized_env_value};
pub(crate) use remote_kubernetes::{
    RemoteKubernetesInstallMemberState, RemoteKubernetesInstallState, cleanup_remote_install_state,
    load_remote_install_state_for_spec, persist_remote_install_state,
    remote_install_state_path_for_spec, sync_gateway_api_install_state,
};
pub use session::{
    current_run_context_path, current_run_context_path_for_project, data_root, project_context_dir,
    project_context_id, session_context_dir, session_context_dir_for_project, session_scope_key,
    suite_root,
};
