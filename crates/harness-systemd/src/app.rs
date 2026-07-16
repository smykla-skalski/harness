pub mod command_context {
    use crate::errors::CliError;

    #[derive(Debug, Clone, Copy)]
    pub struct AppContext;

    pub trait Execute {
        /// Execute the selected lifecycle command.
        ///
        /// # Errors
        /// Returns a lifecycle error when the command cannot complete safely.
        fn execute(&self, context: &AppContext) -> Result<i32, CliError>;
    }
}
