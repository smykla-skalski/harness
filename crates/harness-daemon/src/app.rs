#[cfg(feature = "daemon-runtime")]
#[path = "../../harness-workspace/src/command_context.rs"]
pub(crate) mod command_context;
#[cfg(all(feature = "bridge-runtime", not(feature = "daemon-runtime")))]
pub(crate) mod command_context {
    pub use harness_workspace::command_context::*;
}

#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub use command_context::{AppContext, Execute};

pub fn run_startup_migrations() {
    #[cfg(target_os = "macos")]
    crate::sandbox::migration::run_startup_migration();
}
