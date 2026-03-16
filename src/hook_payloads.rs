use std::collections::HashMap;
use std::io;
use std::path::{Path, PathBuf};
use std::str::FromStr;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::context::RunContext;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::rules;
use crate::workflow::author::{self as author_workflow, AuthorWorkflowState};
use crate::workflow::runner::{self as runner_workflow, RunnerWorkflowState};

pub use crate::shell_parse::{HarnessCommandInvocation, ParsedCommand};

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
            CliErrorKind::hook_payload_invalid(cow!("invalid hook payload: {error}")).into()
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
            CliError::from(CliErrorKind::hook_payload_invalid(cow!(
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

/// Hook context combining event, run context, workflow state, and skill info.
#[derive(Debug)]
pub struct HookContext {
    pub skill: String,
    pub event: HookEvent,
    pub run_dir: Option<PathBuf>,
    pub skill_active: bool,
    pub active_skill: Option<String>,
    pub inactive_reason: Option<String>,
    pub run: Option<RunContext>,
    pub runner_state: Option<RunnerWorkflowState>,
    pub author_state: Option<AuthorWorkflowState>,
}

impl HookContext {
    /// Build hook context from stdin for a given skill.
    ///
    /// Reads the hook envelope from stdin and resolves run context,
    /// runner workflow state, and author workflow state from disk.
    ///
    /// # Errors
    /// Returns `CliError` if stdin cannot be read or the payload is invalid.
    pub fn from_stdin(skill: &str) -> Result<Self, CliError> {
        let event = HookEvent::from_stdin()?;
        let skill_name = skill.to_string();
        let mut context = Self {
            skill: skill_name.clone(),
            event,
            run_dir: None,
            skill_active: true,
            active_skill: Some(skill_name),
            inactive_reason: None,
            run: None,
            runner_state: None,
            author_state: None,
        };
        context.load_context_from_disk();
        Ok(context)
    }

    /// Build hook context from a pre-parsed envelope payload.
    ///
    /// Used when the envelope has already been read (e.g. from a test).
    #[must_use]
    pub fn from_envelope(skill: &str, payload: HookEnvelopePayload) -> Self {
        let skill_name = skill.to_string();
        let mut context = Self {
            skill: skill_name.clone(),
            event: HookEvent { payload },
            run_dir: None,
            skill_active: true,
            active_skill: Some(skill_name),
            inactive_reason: None,
            run: None,
            runner_state: None,
            author_state: None,
        };
        context.load_context_from_disk();
        context
    }

    /// Attempt to load `RunContext`, runner state, and author state from disk.
    fn load_context_from_disk(&mut self) {
        self.load_run_context();
        self.load_runner_state();
        self.load_author_state();
    }

    /// Resolve run context from an explicit `run_dir` or by detecting the current run.
    fn load_run_context(&mut self) {
        if let Some(run_directory) = &self.run_dir {
            match RunContext::from_run_dir(run_directory) {
                Ok(run_context) => self.run = Some(run_context),
                Err(error) => eprintln!("warning: failed to load run context: {error}"),
            }
            return;
        }
        match RunContext::from_current() {
            Ok(Some(run_context)) => {
                self.run_dir = Some(run_context.layout.run_dir());
                self.run = Some(run_context);
            }
            Ok(None) => {}
            Err(error) => eprintln!("warning: failed to load current run context: {error}"),
        }
    }

    /// Load runner workflow state from the run directory (via context or fallback).
    fn load_runner_state(&mut self) {
        let run_directory = self
            .run
            .as_ref()
            .map(|run_context| run_context.layout.run_dir())
            .or_else(|| self.run_dir.clone());

        let Some(run_directory) = run_directory else {
            return;
        };

        match runner_workflow::read_runner_state(&run_directory) {
            Ok(runner_state) => self.runner_state = runner_state,
            Err(error) => eprintln!("warning: failed to load runner state: {error}"),
        }
    }

    /// Load author workflow state when a suite authoring session is active.
    fn load_author_state(&mut self) {
        if !self.is_suite_author() {
            return;
        }
        match author_workflow::read_author_state() {
            Ok(author_state) => self.author_state = author_state,
            Err(error) => eprintln!("warning: failed to load author state: {error}"),
        }
    }

    /// Get the run directory, either from explicit `run_dir` or from `RunContext`.
    #[must_use]
    pub fn effective_run_dir(&self) -> Option<PathBuf> {
        if let Some(run_directory) = &self.run_dir {
            return Some(run_directory.clone());
        }
        self.run
            .as_ref()
            .map(|run_context| run_context.layout.run_dir())
    }

    /// Get the suite directory from the run context metadata.
    #[must_use]
    pub fn suite_dir(&self) -> Option<PathBuf> {
        self.run.as_ref().map(|run_context| {
            Path::new(&run_context.metadata.suite_dir)
                .canonicalize()
                .unwrap_or_else(|_| PathBuf::from(&run_context.metadata.suite_dir))
        })
    }

    /// Tool name from the hook payload.
    #[must_use]
    pub fn tool_name(&self) -> &str {
        &self.event.payload.tool_name
    }

    /// Tool input from the hook payload.
    #[must_use]
    pub fn tool_input(&self) -> &Value {
        &self.event.payload.tool_input
    }

    /// Tool response from the hook payload.
    #[must_use]
    pub fn tool_response(&self) -> &Value {
        &self.event.payload.tool_response
    }

    /// The raw command string from the input payload, if any.
    #[must_use]
    pub fn command_text(&self) -> Option<&str> {
        self.tool_input().get("command").and_then(Value::as_str)
    }

    /// Shell-split command words from the input payload.
    ///
    /// # Errors
    /// Returns `CliError` if shell tokenization fails (e.g. unmatched quotes).
    pub fn command_words(&self) -> Result<Vec<String>, CliError> {
        self.parsed_command()
            .map(|command| command.map_or_else(Vec::new, |parsed| parsed.words().to_vec()))
    }

    /// Write target paths from the input payload.
    #[must_use]
    pub fn write_paths(&self) -> Vec<&Path> {
        let mut paths = Vec::new();
        if let Some(path) = self.tool_input().get("file_path").and_then(Value::as_str) {
            paths.push(Path::new(path));
        }
        if let Some(extra_paths) = self
            .tool_input()
            .get("file_paths")
            .and_then(Value::as_array)
        {
            paths.extend(extra_paths.iter().filter_map(Value::as_str).map(Path::new));
        }
        paths
    }

    /// `AskUserQuestion` prompts from the input payload.
    #[must_use]
    pub fn question_prompts(&self) -> Vec<AskUserQuestionPrompt> {
        deserialize_value_list(self.tool_input().get("questions"))
    }

    /// `AskUserQuestion` answers from the tool response.
    #[must_use]
    pub fn question_answers(&self) -> Vec<AskUserAnswer> {
        deserialize_value_list(self.tool_response().get("answers"))
    }

    /// Last assistant message from the envelope.
    #[must_use]
    pub fn last_assistant_message(&self) -> &str {
        self.event
            .payload
            .last_assistant_message
            .as_deref()
            .unwrap_or("")
    }

    /// Whether the stop hook is active in the envelope.
    #[must_use]
    pub fn stop_hook_active(&self) -> bool {
        self.event.payload.stop_hook_active
    }

    /// Bash stdout from the tool response.
    #[must_use]
    pub fn bash_stdout(&self) -> Option<&str> {
        self.tool_response().get("stdout").and_then(Value::as_str)
    }

    /// Bash stderr from the tool response.
    #[must_use]
    pub fn bash_stderr(&self) -> Option<&str> {
        self.tool_response().get("stderr").and_then(Value::as_str)
    }

    /// Bash exit code from the tool response.
    #[must_use]
    pub fn bash_exit_code(&self) -> Option<i32> {
        self.tool_response()
            .get("exit_code")
            .or_else(|| self.tool_response().get("exitCode"))
            .and_then(Value::as_i64)
            .and_then(|value| i32::try_from(value).ok())
    }

    /// Tool response text from the envelope.
    #[must_use]
    pub fn response_text(&self) -> String {
        render_tool_response_text(self.tool_name(), self.tool_response())
    }

    /// Whether this context is for the suite:run skill.
    #[must_use]
    pub fn is_suite_runner(&self) -> bool {
        self.skill == rules::SKILL_RUN
    }

    /// Whether this context is for the suite:new skill.
    #[must_use]
    pub fn is_suite_author(&self) -> bool {
        self.skill == rules::SKILL_NEW
    }

    /// Shell-split significant words (no control operators or env assignments).
    ///
    /// # Errors
    /// Returns `CliError` if shell tokenization fails.
    pub fn significant_words(&self) -> Result<Vec<String>, CliError> {
        self.parsed_command().map(|command| {
            command.map_or_else(Vec::new, |parsed| parsed.significant_words().to_vec())
        })
    }

    /// Binary heads from each pipeline segment of the command.
    ///
    /// # Errors
    /// Returns `CliError` if shell tokenization fails.
    pub fn command_heads(&self) -> Result<Vec<String>, CliError> {
        self.parsed_command()
            .map(|command| command.map_or_else(Vec::new, |parsed| parsed.heads().to_vec()))
    }

    /// Parsed command view from the input payload, if this tool call has one.
    ///
    /// # Errors
    /// Returns `CliError` if shell tokenization fails.
    pub fn parsed_command(&self) -> Result<Option<ParsedCommand>, CliError> {
        let Some(command_text) = self.command_text() else {
            return Ok(None);
        };
        if command_text.trim().is_empty() {
            return Ok(None);
        }
        ParsedCommand::parse(command_text)
            .map(Some)
            .map_err(|error| {
                CliErrorKind::hook_payload_invalid(cow!("shell tokenization failed: {error}"))
                    .into()
            })
    }
}

fn deserialize_value_list<T>(value: Option<&Value>) -> Vec<T>
where
    T: for<'de> Deserialize<'de>,
{
    value
        .cloned()
        .and_then(|inner| serde_json::from_value(inner).ok())
        .unwrap_or_default()
}

fn render_tool_response_text(tool_name: &str, tool_response: &Value) -> String {
    if tool_name == "Bash" {
        let stdout = tool_response
            .get("stdout")
            .and_then(Value::as_str)
            .unwrap_or("");
        let stderr = tool_response
            .get("stderr")
            .and_then(Value::as_str)
            .unwrap_or("");
        let exit_code = tool_response
            .get("exit_code")
            .or_else(|| tool_response.get("exitCode"))
            .and_then(Value::as_i64)
            .and_then(|value| i32::try_from(value).ok())
            .unwrap_or_default();
        return format!(
            "exit code: {exit_code}\n--- STDOUT ---\n{stdout}\n--- STDERR ---\n{stderr}"
        );
    }

    match tool_response {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        other => serde_json::to_string_pretty(other).unwrap_or_else(|_| other.to_string()),
    }
}

/// Extra types used in hook payload extraction.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolTracking {
    #[serde(default)]
    pub tracked_tools: HashMap<String, u32>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn envelope_from_str_parses() {
        let json = r#"{"tool_name": "Read", "tool_input": {"file_path": "/workspace/file.txt"}}"#;
        let envelope: HookEnvelopePayload = json.parse().unwrap();
        assert_eq!(envelope.tool_name, "Read");
        assert_eq!(envelope.tool_input["file_path"], "/workspace/file.txt");
    }

    #[test]
    fn envelope_from_str_invalid() {
        let result = "not json".parse::<HookEnvelopePayload>();
        assert!(result.is_err());
    }

    #[test]
    fn envelope_from_json_empty_object() {
        let envelope = HookEnvelopePayload::from_json_text("{}").unwrap();
        assert!(envelope.tool_name.is_empty());
        assert_eq!(envelope.tool_input, Value::Null);
        assert_eq!(envelope.tool_response, Value::Null);
        assert!(!envelope.stop_hook_active);
        assert!(envelope.raw_keys.is_empty());
    }

    #[test]
    fn envelope_from_json_with_command() {
        let json = r#"{"tool_name": "Bash", "tool_input": {"command": "kubectl get pods"}}"#;
        let envelope = HookEnvelopePayload::from_json_text(json).unwrap();
        assert_eq!(envelope.tool_name, "Bash");
        assert_eq!(envelope.tool_input["command"], "kubectl get pods");
    }

    #[test]
    fn envelope_from_json_with_questions() {
        let json = r#"{
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [{
                    "question": "Install validator?",
                    "options": [
                        {"label": "Yes", "description": "Install it"},
                        {"label": "No", "description": "Skip"}
                    ]
                }]
            }
        }"#;
        let envelope = HookEnvelopePayload::from_json_text(json).unwrap();
        let context = HookContext::from_envelope("suite:run", envelope);
        let prompts = context.question_prompts();
        assert_eq!(prompts.len(), 1);
        let prompt = &prompts[0];
        assert_eq!(prompt.question, "Install validator?");
        assert_eq!(prompt.option_labels(), vec!["Yes", "No"]);
        assert_eq!(prompt.question_head(), "Install validator?");
    }

    #[test]
    fn envelope_from_json_invalid() {
        let result = HookEnvelopePayload::from_json_text("not json");
        assert!(result.is_err());
        let error = result.unwrap_err();
        assert_eq!(error.code(), "KSH001");
        assert!(error.message().contains("invalid hook payload"));
    }

    #[test]
    fn envelope_from_json_full_envelope() {
        let json = r#"{
            "tool_name": "Agent",
            "tool_input": {"description": "run preflight"},
            "transcript_path": "/tmp/transcript.json",
            "stop_hook_active": true,
            "raw_keys": ["key1", "key2"]
        }"#;
        let envelope = HookEnvelopePayload::from_json_text(json).unwrap();
        assert_eq!(envelope.tool_name, "Agent");
        assert_eq!(
            envelope.transcript_path.as_deref(),
            Some(Path::new("/tmp/transcript.json"))
        );
        assert!(envelope.stop_hook_active);
        assert_eq!(envelope.raw_keys, vec!["key1", "key2"]);
    }

    #[test]
    fn context_from_envelope_sets_skill() {
        let payload = HookEnvelopePayload::from_json_text("{}").unwrap();
        let context = HookContext::from_envelope("suite:run", payload);
        assert_eq!(context.skill, "suite:run");
        assert!(context.skill_active);
        assert_eq!(context.active_skill.as_deref(), Some("suite:run"));
    }

    #[test]
    fn question_head_returns_first_line() {
        let prompt = AskUserQuestionPrompt {
            question: "First line\nSecond line\nThird".to_string(),
            header: None,
            options: vec![],
            multi_select: false,
        };
        assert_eq!(prompt.question_head(), "First line");
    }

    #[test]
    fn response_text_renders_bash_output() {
        let json = r#"{
            "tool_name": "Bash",
            "tool_response": {"stdout": "ok", "stderr": "warn", "exit_code": 3}
        }"#;
        let payload = HookEnvelopePayload::from_json_text(json).unwrap();
        let context = HookContext::from_envelope("suite:run", payload);
        assert_eq!(
            context.response_text(),
            "exit code: 3\n--- STDOUT ---\nok\n--- STDERR ---\nwarn"
        );
    }

    #[test]
    fn response_text_returns_empty_when_absent() {
        let payload = HookEnvelopePayload::from_json_text("{}").unwrap();
        let context = HookContext::from_envelope("suite:run", payload);
        assert_eq!(context.response_text(), "");
    }

    #[test]
    fn response_text_renders_non_bash_json() {
        let json = r#"{
            "tool_name": "AskUserQuestion",
            "tool_response": {"answers": [{"question": "Q", "answer": "A"}]}
        }"#;
        let payload = HookEnvelopePayload::from_json_text(json).unwrap();
        let context = HookContext::from_envelope("suite:run", payload);
        assert!(context.response_text().contains("\"answer\": \"A\""));
    }
}
