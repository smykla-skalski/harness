use std::io;
use std::path::PathBuf;
use std::str::FromStr;

use crate::errors::{CliError, CliErrorKind};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// An option in an `AskUserQuestion` prompt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AskUserQuestionOption {
    pub label: String,
    #[serde(default)]
    pub description: String,
}

/// An `AskUserQuestion` prompt with header, options, multi-select.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AskUserQuestionPrompt {
    pub question: String,
    #[serde(default)]
    pub header: Option<String>,
    #[serde(default)]
    pub options: Vec<AskUserQuestionOption>,
    #[serde(default)]
    pub multi_select: bool,
}

impl AskUserQuestionPrompt {
    /// Option labels as borrowed string slices.
    #[must_use]
    pub fn option_labels(&self) -> Vec<&str> {
        self.options
            .iter()
            .map(|option| option.label.as_str())
            .collect()
    }

    /// First line of the question text.
    #[must_use]
    pub fn question_head(&self) -> &str {
        self.question
            .lines()
            .next()
            .unwrap_or(&self.question)
            .trim()
    }
}

/// Answer to an `AskUserQuestion`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AskUserAnswer {
    pub question: String,
    pub answer: String,
}

/// The full hook envelope payload from Claude Code.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct HookEnvelopePayload {
    #[serde(default)]
    pub tool_name: String,
    #[serde(default)]
    pub tool_input: Value,
    #[serde(default)]
    pub tool_response: Value,
    #[serde(default)]
    pub last_assistant_message: Option<String>,
    #[serde(default)]
    pub transcript_path: Option<PathBuf>,
    #[serde(default)]
    pub stop_hook_active: bool,
    #[serde(default)]
    pub raw_keys: Vec<String>,
}

impl FromStr for HookEnvelopePayload {
    type Err = CliError;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        Self::from_json_text(text)
    }
}

impl HookEnvelopePayload {
    /// Parse from JSON text.
    ///
    /// # Errors
    /// Returns `CliError` if the text is not valid JSON or does not match the
    /// expected envelope shape.
    pub fn from_json_text(text: &str) -> Result<Self, CliError> {
        serde_json::from_str(text).map_err(|error| {
            CliErrorKind::hook_payload_invalid(format!("invalid hook payload: {error}")).into()
        })
    }

    /// Parse from stdin.
    ///
    /// # Errors
    /// Returns `CliError` if stdin cannot be read or the payload is invalid.
    pub fn from_stdin() -> Result<Self, CliError> {
        use io::Read;
        let mut text = String::new();
        io::stdin().read_to_string(&mut text).map_err(|error| {
            CliError::from(CliErrorKind::hook_payload_invalid(format!(
                "failed to read stdin: {error}"
            )))
        })?;
        Self::from_json_text(&text)
    }
}

/// High-level hook event wrapping the envelope.
#[derive(Debug, Clone)]
pub struct HookEvent {
    pub payload: HookEnvelopePayload,
}

impl HookEvent {
    /// Parse from stdin.
    ///
    /// # Errors
    /// Returns `CliError` if stdin cannot be read or the payload is invalid.
    pub fn from_stdin() -> Result<Self, CliError> {
        let payload = HookEnvelopePayload::from_stdin()?;
        Ok(Self { payload })
    }
}

#[cfg(test)]
#[path = "payloads/tests.rs"]
mod tests;
