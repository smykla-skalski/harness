#[path = "../../../src/workspace/adopter.rs"]
pub mod adopter;
#[path = "../../../src/workspace/ids.rs"]
pub mod ids;
#[path = "../../../src/workspace/layout.rs"]
pub mod layout;
#[path = "../../../src/workspace/orphan_cleanup.rs"]
pub mod orphan_cleanup;
#[path = "../../../src/workspace/paths.rs"]
mod paths;
#[path = "../../../src/workspace/project_resolver.rs"]
pub mod project_resolver;
#[path = "../../../src/workspace/session.rs"]
mod session;
#[path = "../../../src/workspace/socket_paths.rs"]
pub mod socket_paths;
#[path = "../../../src/workspace/worktree.rs"]
pub mod worktree;

pub use crate::git::identity::{
    GitCheckoutIdentity, GitCheckoutKind, canonical_checkout_root, resolve_git_checkout_identity,
};
#[cfg(target_os = "macos")]
pub use paths::legacy_macos_root;
pub use paths::{
    HARNESS_PREFIX, NON_INDEXABLE_MARKER_NAME, dirs_home, ensure_non_indexable, harness_data_root,
    shorten_path, utc_now,
};
pub(crate) use paths::{host_home_dir, normalized_env_value};
pub use session::{
    current_run_context_path, current_run_context_path_for_project, data_root, project_context_dir,
    project_context_id, session_context_dir, session_context_dir_for_project, session_scope_key,
    suite_root,
};
