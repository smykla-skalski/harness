use crate::errors::CliError;
use crate::kernel::command_intent::ParsedCommand;

use super::GuardContext;

impl GuardContext {
    #[must_use]
    pub fn command_text(&self) -> Option<&str> {
        self.tool
            .as_ref()
            .and_then(|tool| tool.input.command_text())
            .or_else(|| {
                self.tool_input()
                    .get("command")
                    .and_then(serde_json::Value::as_str)
            })
    }

    /// # Errors
    /// Returns `CliError` when shell tokenization of the command text fails.
    pub fn command_words(&self) -> Result<&[String], CliError> {
        self.parsed_command()
            .map(|command| command.map_or(&[][..], ParsedCommand::words))
    }

    /// # Errors
    /// Returns `CliError` when shell tokenization of the command text fails.
    pub fn significant_words(&self) -> Result<Vec<&str>, CliError> {
        self.parsed_command().map(|command| {
            command.map_or_else(Vec::new, |parsed| parsed.significant_words().collect())
        })
    }

    /// # Errors
    /// Returns `CliError` when shell tokenization of the command text fails.
    pub fn command_heads(&self) -> Result<&[String], CliError> {
        self.parsed_command()
            .map(|command| command.map_or(&[][..], ParsedCommand::heads))
    }

    /// # Errors
    /// Returns `CliError` when shell tokenization of the command text fails.
    pub fn parsed_command(&self) -> Result<Option<&ParsedCommand>, CliError> {
        self.interaction.parsed_command()
    }
}
