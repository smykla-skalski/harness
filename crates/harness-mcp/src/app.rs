/// Minimal command execution boundary shared with the canonical MCP transport.
pub mod command_context {
    use crate::errors::CliError;

    /// Runtime context for standalone MCP command execution.
    #[derive(Clone, Debug, Default)]
    pub struct AppContext;

    impl AppContext {
        #[must_use]
        pub fn production() -> Self {
            Self
        }
    }

    /// Uniform command execution contract used by the MCP command types.
    pub trait Execute {
        /// Execute the command and return its process exit code.
        ///
        /// # Errors
        /// Returns a [`CliError`] when the command cannot run.
        fn execute(&self, context: &AppContext) -> Result<i32, CliError>;
    }
}

pub use command_context::{AppContext, Execute};

#[cfg(test)]
mod tests {
    use super::AppContext;

    #[test]
    fn production_context_is_cloneable() {
        let context = AppContext::production();
        let _clone = context.clone();
    }
}
