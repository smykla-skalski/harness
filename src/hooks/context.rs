use std::borrow::Cow;
use std::env;
use std::path::{Path, PathBuf};

use serde_json::Value;
use tracing::warn;

use crate::context::RunContext;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::hooks::payloads::{AskUserAnswer, AskUserQuestionPrompt, HookEnvelopePayload};
use crate::rules;
use crate::shell_parse::ParsedCommand;
use crate::workflow::author::{self as author_workflow, AuthorWorkflowState};
use crate::workflow::runner::{self as runner_workflow, RunnerWorkflowState};

/// Opaque raw agent payload preserved for adapter-specific features.
#[derive(Debug, Clone)]
pub struct RawPayload(Value);

impl RawPayload {
    #[must_use]
    pub fn new(value: Value) -> Self {
        Self(value)
    }

    #[must_use]
    pub(crate) fn as_value(&self) -> &Value {
        &self.0
    }
}

/// Events normalized across supported agent protocols.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum NormalizedEvent {
    BeforeToolUse,
    AfterToolUse,
    AfterToolUseFailure,
    SessionStart,
    SessionEnd,
    AgentStart,
    AgentStop,
    SubagentStart,
    SubagentStop,
    BeforeCompaction,
    AfterCompaction,
    Notification,
    AgentSpecific(String),
}

impl NormalizedEvent {
    #[must_use]
    pub fn unspecified() -> Self {
        Self::AgentSpecific("unspecified".to_string())
    }

    #[must_use]
    pub fn is_unspecified(&self) -> bool {
        matches!(self, Self::AgentSpecific(name) if name == "unspecified")
    }
}

/// Session-scoped information available to all agents.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionContext {
    pub session_id: String,
    pub cwd: PathBuf,
    pub transcript_path: Option<PathBuf>,
}

/// Normalized tool categories shared across supported agents.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum ToolCategory {
    Shell,
    FileRead,
    FileWrite,
    FileEdit,
    FileSearch,
    Agent,
    WebFetch,
    WebSearch,
    Custom(String),
}

/// Agent-agnostic representation of tool input.
#[derive(Debug, Clone, PartialEq)]
#[non_exhaustive]
pub enum ToolInput {
    Shell {
        command: String,
        description: Option<String>,
    },
    FileRead {
        path: PathBuf,
    },
    FileWrite {
        path: PathBuf,
        content: String,
    },
    FileEdit {
        path: PathBuf,
        old_text: String,
        new_text: String,
    },
    FileSearch {
        pattern: String,
        path: Option<PathBuf>,
    },
    Other(Value),
}

/// Tool metadata extracted by an adapter.
#[derive(Debug, Clone, PartialEq)]
pub struct ToolContext {
    pub category: ToolCategory,
    pub original_name: String,
    pub input: ToolInput,
    pub input_raw: Value,
    pub response: Option<Value>,
}

/// Agent lifecycle metadata extracted by an adapter.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentContext {
    pub agent_id: Option<String>,
    pub agent_type: Option<String>,
    pub prompt: Option<String>,
    pub response: Option<String>,
}

/// Skill metadata carried through the hook engine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillContext {
    pub active: bool,
    pub name: Option<String>,
    pub is_runner: bool,
    pub is_author: bool,
}

impl SkillContext {
    #[must_use]
    pub fn inactive() -> Self {
        Self {
            active: false,
            name: None,
            is_runner: false,
            is_author: false,
        }
    }

    #[must_use]
    pub fn from_skill_name(skill: &str) -> Self {
        Self {
            active: !skill.is_empty(),
            name: (!skill.is_empty()).then(|| skill.to_string()),
            is_runner: skill == rules::SKILL_RUN,
            is_author: skill == rules::SKILL_NEW,
        }
    }
}

/// Agent-agnostic context produced by the adapter layer.
#[derive(Debug, Clone)]
pub struct NormalizedHookContext {
    pub event: NormalizedEvent,
    pub session: SessionContext,
    pub tool: Option<ToolContext>,
    pub agent: Option<AgentContext>,
    pub skill: SkillContext,
    pub raw: RawPayload,
}

impl NormalizedHookContext {
    #[must_use]
    pub fn with_skill(mut self, skill: &str) -> Self {
        self.skill = SkillContext::from_skill_name(skill);
        self
    }

    #[must_use]
    pub fn with_default_event(mut self, event: NormalizedEvent) -> Self {
        if self.event.is_unspecified() {
            self.event = event;
        }
        self
    }
}

#[derive(Debug, Clone)]
enum ParsedCommandState {
    Missing,
    Parsed(ParsedCommand),
    Error(String),
}

impl ParsedCommandState {
    fn from_command_text(command_text: Option<&str>) -> Self {
        let Some(command_text) = command_text else {
            return Self::Missing;
        };
        if command_text.trim().is_empty() {
            return Self::Missing;
        }
        match ParsedCommand::parse(command_text) {
            Ok(parsed) => Self::Parsed(parsed),
            Err(error) => Self::Error(error.to_string()),
        }
    }

    fn as_result(&self) -> Result<Option<&ParsedCommand>, CliError> {
        match self {
            Self::Missing => Ok(None),
            Self::Parsed(parsed) => Ok(Some(parsed)),
            Self::Error(error) => Err(CliErrorKind::hook_payload_invalid(cow!(
                "shell tokenization failed: {error}"
            ))
            .into()),
        }
    }
}

/// Guard-facing context derived from the normalized adapter context.
///
/// This intentionally excludes direct raw-payload access while preserving the
/// hook-facing helpers the existing policy modules rely on.
#[derive(Debug)]
pub struct GuardContext {
    pub event: NormalizedEvent,
    pub session: SessionContext,
    pub tool: Option<ToolContext>,
    pub agent: Option<AgentContext>,
    pub skill: SkillContext,
    pub skill_active: bool,
    pub run_dir: Option<PathBuf>,
    pub run: Option<RunContext>,
    pub runner_state: Option<RunnerWorkflowState>,
    pub author_state: Option<AuthorWorkflowState>,
    tool_name: String,
    tool_input: Value,
    tool_response: Value,
    last_assistant_message: Option<String>,
    stop_hook_active: bool,
    parsed_command: ParsedCommandState,
}

impl GuardContext {
    #[must_use]
    pub fn from_normalized(normalized: NormalizedHookContext) -> Self {
        let tool_name = normalized
            .tool
            .as_ref()
            .map_or_else(String::new, |tool| tool.original_name.clone());
        let tool_input = normalized
            .tool
            .as_ref()
            .map_or(Value::Null, |tool| tool.input_raw.clone());
        let tool_response = normalized
            .tool
            .as_ref()
            .and_then(|tool| tool.response.clone())
            .unwrap_or(Value::Null);
        let last_assistant_message = normalized
            .raw
            .as_value()
            .get("last_assistant_message")
            .and_then(Value::as_str)
            .map(ToString::to_string)
            .or_else(|| {
                normalized
                    .agent
                    .as_ref()
                    .and_then(|agent| agent.response.clone())
            });
        let stop_hook_active = normalized
            .raw
            .as_value()
            .get("stop_hook_active")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let parsed_command = ParsedCommandState::from_command_text(
            tool_input.get("command").and_then(Value::as_str),
        );
        let skill_active = normalized.skill.active;
        let mut context = Self {
            event: normalized.event,
            session: normalized.session,
            tool: normalized.tool,
            agent: normalized.agent,
            skill: normalized.skill,
            skill_active,
            run_dir: None,
            run: None,
            runner_state: None,
            author_state: None,
            tool_name,
            tool_input,
            tool_response,
            last_assistant_message,
            stop_hook_active,
            parsed_command,
        };
        context.load_context_from_disk();
        context
    }

    #[must_use]
    pub fn from_envelope(skill: &str, payload: HookEnvelopePayload) -> Self {
        let normalized = normalized_from_envelope(skill, payload);
        Self::from_normalized(normalized)
    }

    #[cfg(test)]
    #[must_use]
    pub(crate) fn from_test_envelope(skill: &str, payload: HookEnvelopePayload) -> Self {
        let normalized = normalized_from_envelope(skill, payload);
        let tool_name = normalized
            .tool
            .as_ref()
            .map_or_else(String::new, |tool| tool.original_name.clone());
        let tool_input = normalized
            .tool
            .as_ref()
            .map_or(Value::Null, |tool| tool.input_raw.clone());
        let tool_response = normalized
            .tool
            .as_ref()
            .and_then(|tool| tool.response.clone())
            .unwrap_or(Value::Null);
        let last_assistant_message = normalized
            .raw
            .as_value()
            .get("last_assistant_message")
            .and_then(Value::as_str)
            .map(ToString::to_string)
            .or_else(|| {
                normalized
                    .agent
                    .as_ref()
                    .and_then(|agent| agent.response.clone())
            });
        let stop_hook_active = normalized
            .raw
            .as_value()
            .get("stop_hook_active")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let parsed_command = ParsedCommandState::from_command_text(
            tool_input.get("command").and_then(Value::as_str),
        );
        Self {
            event: normalized.event.clone(),
            session: normalized.session.clone(),
            tool: normalized.tool.clone(),
            agent: normalized.agent.clone(),
            skill: normalized.skill.clone(),
            skill_active: normalized.skill.active,
            run_dir: None,
            run: None,
            runner_state: None,
            author_state: None,
            tool_name,
            tool_input,
            tool_response,
            last_assistant_message,
            stop_hook_active,
            parsed_command,
        }
    }

    fn load_context_from_disk(&mut self) {
        self.load_run_context();
        self.load_runner_state();
        self.load_author_state();
    }

    fn load_run_context(&mut self) {
        if let Some(run_directory) = &self.run_dir {
            match RunContext::from_run_dir(run_directory) {
                Ok(run_context) => self.run = Some(run_context),
                Err(error) => warn!(%error, "failed to load run context"),
            }
            return;
        }
        match RunContext::from_current() {
            Ok(Some(run_context)) => {
                self.run_dir = Some(run_context.layout.run_dir());
                self.run = Some(run_context);
            }
            Ok(None) => {}
            Err(error) => warn!(%error, "failed to load current run context"),
        }
    }

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
            Err(error) => warn!(%error, "failed to load runner state"),
        }
    }

    fn load_author_state(&mut self) {
        if !self.is_suite_author() {
            return;
        }
        match author_workflow::read_author_state() {
            Ok(author_state) => self.author_state = author_state,
            Err(error) => warn!(%error, "failed to load author state"),
        }
    }

    #[must_use]
    pub fn effective_run_dir(&self) -> Option<Cow<'_, Path>> {
        if let Some(run_directory) = &self.run_dir {
            return Some(Cow::Borrowed(run_directory.as_path()));
        }
        self.run
            .as_ref()
            .map(|run_context| Cow::Owned(run_context.layout.run_dir()))
    }

    #[must_use]
    pub fn suite_dir(&self) -> Option<Cow<'_, Path>> {
        self.run.as_ref().map(|run_context| {
            Path::new(&run_context.metadata.suite_dir)
                .canonicalize()
                .map_or_else(
                    |_| Cow::Borrowed(Path::new(&run_context.metadata.suite_dir)),
                    Cow::Owned,
                )
        })
    }

    #[must_use]
    pub fn tool_name(&self) -> &str {
        &self.tool_name
    }

    #[must_use]
    pub fn tool_input(&self) -> &Value {
        &self.tool_input
    }

    #[must_use]
    pub fn tool_response(&self) -> &Value {
        &self.tool_response
    }

    #[must_use]
    pub fn command_text(&self) -> Option<&str> {
        self.tool_input().get("command").and_then(Value::as_str)
    }

    /// # Errors
    /// Returns `CliError` when shell tokenization of the command text fails.
    pub fn command_words(&self) -> Result<&[String], CliError> {
        self.parsed_command()
            .map(|command| command.map_or(&[][..], ParsedCommand::words))
    }

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

    #[must_use]
    pub fn question_prompts(&self) -> Vec<AskUserQuestionPrompt> {
        deserialize_value_list(self.tool_input().get("questions"))
    }

    #[must_use]
    pub fn question_answers(&self) -> Vec<AskUserAnswer> {
        deserialize_value_list(self.tool_response().get("answers"))
    }

    #[must_use]
    pub fn last_assistant_message(&self) -> &str {
        self.last_assistant_message.as_deref().unwrap_or("")
    }

    #[must_use]
    pub fn stop_hook_active(&self) -> bool {
        self.stop_hook_active
    }

    #[must_use]
    pub fn bash_stdout(&self) -> Option<&str> {
        self.tool_response().get("stdout").and_then(Value::as_str)
    }

    #[must_use]
    pub fn bash_stderr(&self) -> Option<&str> {
        self.tool_response().get("stderr").and_then(Value::as_str)
    }

    #[must_use]
    pub fn bash_exit_code(&self) -> Option<i32> {
        self.tool_response()
            .get("exit_code")
            .or_else(|| self.tool_response().get("exitCode"))
            .and_then(Value::as_i64)
            .and_then(|value| i32::try_from(value).ok())
    }

    #[must_use]
    pub fn response_text(&self) -> String {
        render_tool_response_text(self.tool_name(), self.tool_response())
    }

    #[must_use]
    pub fn is_suite_runner(&self) -> bool {
        self.skill.is_runner
    }

    #[must_use]
    pub fn is_suite_author(&self) -> bool {
        self.skill.is_author
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
        self.parsed_command.as_result()
    }
}

fn normalized_from_envelope(skill: &str, payload: HookEnvelopePayload) -> NormalizedHookContext {
    let raw = serde_json::to_value(&payload).unwrap_or(Value::Null);
    let tool_name = payload.tool_name;
    let input_raw = payload.tool_input;
    let response_raw = payload.tool_response;
    let tool = (!tool_name.is_empty()).then(|| ToolContext {
        category: normalize_legacy_tool(&tool_name),
        input: normalize_tool_input(&tool_name, &input_raw),
        original_name: tool_name,
        input_raw,
        response: (!response_raw.is_null()).then_some(response_raw),
    });

    NormalizedHookContext {
        event: NormalizedEvent::unspecified(),
        session: SessionContext {
            session_id: String::new(),
            cwd: env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
            transcript_path: payload.transcript_path,
        },
        tool,
        agent: payload.last_assistant_message.map(|response| AgentContext {
            agent_id: None,
            agent_type: None,
            prompt: None,
            response: Some(response),
        }),
        skill: SkillContext::from_skill_name(skill),
        raw: RawPayload::new(raw),
    }
}

fn normalize_legacy_tool(name: &str) -> ToolCategory {
    match name {
        "Bash" => ToolCategory::Shell,
        "Read" => ToolCategory::FileRead,
        "Write" => ToolCategory::FileWrite,
        "Edit" => ToolCategory::FileEdit,
        "Glob" | "Grep" => ToolCategory::FileSearch,
        "Agent" => ToolCategory::Agent,
        "WebFetch" => ToolCategory::WebFetch,
        "WebSearch" => ToolCategory::WebSearch,
        other => ToolCategory::Custom(other.to_string()),
    }
}

fn normalize_tool_input(tool_name: &str, input: &Value) -> ToolInput {
    match tool_name {
        "Bash" => ToolInput::Shell {
            command: input
                .get("command")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            description: input
                .get("description")
                .and_then(Value::as_str)
                .map(ToString::to_string),
        },
        "Read" => ToolInput::FileRead {
            path: PathBuf::from(
                input
                    .get("file_path")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            ),
        },
        "Write" => ToolInput::FileWrite {
            path: PathBuf::from(
                input
                    .get("file_path")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            ),
            content: input
                .get("content")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        },
        "Edit" => ToolInput::FileEdit {
            path: PathBuf::from(
                input
                    .get("file_path")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            ),
            old_text: input
                .get("old_text")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            new_text: input
                .get("new_text")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        },
        "Glob" | "Grep" => ToolInput::FileSearch {
            pattern: input
                .get("pattern")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            path: input.get("path").and_then(Value::as_str).map(PathBuf::from),
        },
        _ => ToolInput::Other(input.clone()),
    }
}

fn deserialize_value_list<T>(value: Option<&Value>) -> Vec<T>
where
    T: for<'de> serde::Deserialize<'de>,
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
