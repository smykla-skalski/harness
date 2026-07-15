#[path = "../../../src/app/command_context.rs"]
pub(crate) mod command_context;

pub use command_context::{AppContext, Execute};

pub fn run_startup_migrations() {
    #[cfg(target_os = "macos")]
    crate::sandbox::migration::run_startup_migration();
}
