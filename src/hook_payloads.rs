use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::errors::CliError;

/// A write request from a hook envelope.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HookWriteRequest {
    pub file_path: String,
}

/// An option in an AskUserQuestion prompt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AskUserQuestionOption {
    pub label: String,
    #[serde(default)]
    pub description: String,
}

/// An AskUserQuestion prompt with header, options, multi-select.
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
    /// Option labels as a tuple of strings.
    #[must_use]
    pub fn option_labels(&self) -> Vec<String> {
        self.options.iter().map(|o| o.label.clone()).collect()
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

/// Answer to an AskUserQuestion.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AskUserAnswer {
    pub question: String,
    pub answer: String,
}

/// Annotation payload.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AskUserAnnotation {
    pub question: String,
    pub notes: String,
}

/// Hook message payload extracted from tool input.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HookMessagePayload {
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub file_path: Option<String>,
    #[serde(default)]
    pub writes: Vec<HookWriteRequest>,
    #[serde(default)]
    pub questions: Vec<AskUserQuestionPrompt>,
    #[serde(default)]
    pub answers: Vec<AskUserAnswer>,
    #[serde(default)]
    pub annotations: Vec<AskUserAnnotation>,
}

/// The full hook envelope payload from Claude Code.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HookEnvelopePayload {
    #[serde(default)]
    pub root: Option<String>,
    #[serde(default)]
    pub input_payload: Option<HookMessagePayload>,
    #[serde(default)]
    pub tool_input: Option<serde_json::Value>,
    #[serde(default)]
    pub response: Option<serde_json::Value>,
    #[serde(default)]
    pub last_assistant_message: Option<String>,
    #[serde(default)]
    pub transcript_path: Option<String>,
    #[serde(default)]
    pub stop_hook_active: bool,
    #[serde(default)]
    pub raw_keys: Vec<String>,
}

impl HookEnvelopePayload {
    /// Parse from JSON text.
    ///
    /// # Errors
    /// Returns `CliError` on parse failure.
    pub fn from_json_text(_text: &str) -> Result<Self, CliError> {
        todo!()
    }

    /// Parse from stdin.
    ///
    /// # Errors
    /// Returns `CliError` on parse failure.
    pub fn from_stdin() -> Result<Self, CliError> {
        todo!()
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
    /// Returns `CliError` on parse failure.
    pub fn from_stdin() -> Result<Self, CliError> {
        todo!()
    }
}

/// Hook context combining event, run context, workflow state, and skill info.
#[derive(Debug)]
pub struct HookContext {
    pub skill: String,
    pub event: HookEvent,
    pub run_dir: Option<std::path::PathBuf>,
    pub skill_active: bool,
    pub active_skill: Option<String>,
    pub inactive_reason: Option<String>,
}

impl HookContext {
    /// Build from stdin for a given skill.
    ///
    /// # Errors
    /// Returns `CliError` on parse failure.
    pub fn from_stdin(_skill: &str) -> Result<Self, CliError> {
        todo!()
    }
}

/// Extra types used in hook payload extraction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolTracking {
    #[serde(default)]
    pub tracked_tools: HashMap<String, u32>,
}

#[cfg(test)]
mod tests {}
