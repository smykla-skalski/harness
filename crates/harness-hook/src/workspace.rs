#[path = "../../../src/workspace/compact/mod.rs"]
pub mod compact;
#[path = "../../../src/git/identity.rs"]
mod identity;
#[path = "../../../src/workspace/ids.rs"]
pub mod ids;
#[path = "../../../src/workspace/layout.rs"]
pub mod layout;
#[path = "../../../src/workspace/paths.rs"]
pub mod paths;
#[path = "../../../src/workspace/session.rs"]
pub mod session;

pub use identity::{
    GitCheckoutIdentity, GitCheckoutKind, canonical_checkout_root, resolve_git_checkout_identity,
};
pub(crate) use paths::normalized_env_value;
pub use paths::{HARNESS_PREFIX, dirs_home, harness_data_root, utc_now};
pub use session::{
    current_run_context_path, data_root, project_context_dir, session_context_dir,
    session_scope_key,
};

#[must_use]
pub const fn compact_handoff_version() -> u32 {
    compact::handoff_version()
}
