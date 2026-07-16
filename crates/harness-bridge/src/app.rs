use crate::errors::CliError;

pub trait Execute {
    /// Execute the command in the supplied application context.
    ///
    /// # Errors
    ///
    /// Returns an error when the command cannot complete.
    fn execute(&self, context: &AppContext) -> Result<i32, CliError>;
}

#[derive(Clone, Debug, Default)]
pub struct AppContext;

impl AppContext {
    #[must_use]
    pub const fn production() -> Self {
        Self
    }
}

pub mod command_context {
    pub use super::{AppContext, Execute};
}

/// Run process-start migrations before executing a bridge command.
pub fn run_startup_migrations() {
    #[cfg(target_os = "macos")]
    crate::startup_migration::run_startup_migration();
}
