pub mod cli;
pub(crate) mod command_context;
mod worker_routes;

#[cfg(target_os = "macos")]
use crate::sandbox::migration::run_startup_migration;

pub use command_context::{AppContext, Execute};

/// Run process-start migrations shared by the root CLI and dedicated workers.
pub fn run_startup_migrations() {
    #[cfg(target_os = "macos")]
    run_startup_migration();
}
