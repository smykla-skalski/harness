use std::borrow::Cow;
use std::env;
use std::path::{Path, PathBuf};

use serde_json::Value;
use tracing::warn;

use crate::authoring::workflow::{self as author_workflow, AuthorWorkflowState};
use crate::errors::{CliError, CliErrorKind};
use crate::hooks::protocol::context::{
    AgentContext, NormalizedEvent, NormalizedHookContext, RawPayload, SessionContext, SkillContext,
};
use crate::hooks::protocol::payloads::{AskUserAnswer, AskUserQuestionPrompt, HookEnvelopePayload};
use crate::kernel::command_intent::{ObservedCommand, ParsedCommand};
use crate::kernel::tooling::{ToolContext, legacy_tool_context};
use crate::run::context::RunContext;
use crate::run::workflow::{self as runner_workflow, RunnerWorkflowState};

#[derive(Debug, Clone)]
enum ParsedCommandState {
    Missing,
    Parsed(ObservedCommand),
}

impl ParsedCommandState {
    fn from_command_text(command_text: Option<&str>) -> Self {
        let Some(command_text) = command_text else {
            return Self::Missing;
        };
        if command_text.trim().is_empty() {
            return Self::Missing;
        }
        Self::Parsed(ObservedCommand::parse(command_text))
    }

    fn as_result(&self) -> Result<Option<&ParsedCommand>, CliError> {
        match self {
            Self::Missing => Ok(None),
            Self::Parsed(observed) => observed.parsed().map_or_else(
                || {
                    let error = observed
                        .tokenization_error()
                        .unwrap_or("unknown parse error");
                    Err(CliErrorKind::hook_payload_invalid(format!(
                        "shell tokenization failed: {error}"
                    ))
                    .into())
                },
                |parsed| Ok(Some(parsed)),
            ),
        }
    }
}

#[derive(Debug, Clone)]
struct HookInteraction {
    tool_name: String,
    tool_input: Value,
    tool_response: Value,
    last_assistant_message: Option<String>,
    stop_hook_active: bool,
    parsed_command: ParsedCommandState,
}

impl HookInteraction {
    fn from_normalized(normalized: &NormalizedHookContext) -> Self {
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
            tool_name,
            tool_input,
            tool_response,
            last_assistant_message,
            stop_hook_active,
            parsed_command,
        }
    }
}

#[derive(Debug, Clone, Default)]
struct HydratedHookState {
    run_dir: Option<PathBuf>,
    run: Option<RunContext>,
    runner_state: Option<RunnerWorkflowState>,
    author_state: Option<AuthorWorkflowState>,
}

impl HydratedHookState {
    fn from_skill(skill: &SkillContext) -> Self {
        let mut state = Self::default();
        state.load_run_context();
        state.load_runner_state();
        state.load_author_state(skill);
        state
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

    fn load_author_state(&mut self, skill: &SkillContext) {
        if !skill.is_author {
            return;
        }
        match author_workflow::read_author_state() {
            Ok(author_state) => self.author_state = author_state,
            Err(error) => warn!(%error, "failed to load author state"),
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
    interaction: HookInteraction,
}

impl GuardContext {
    #[must_use]
    pub fn from_normalized(normalized: NormalizedHookContext) -> Self {
        let normalized = hydrate_normalized_context(normalized);
        let interaction = HookInteraction::from_normalized(&normalized);
        let skill_active = normalized.skill.active;
        let hydrated = HydratedHookState::from_skill(&normalized.skill);
        Self {
            event: normalized.event,
            session: normalized.session,
            tool: normalized.tool,
            agent: normalized.agent,
            skill: normalized.skill,
            skill_active,
            run_dir: hydrated.run_dir,
            run: hydrated.run,
            runner_state: hydrated.runner_state,
            author_state: hydrated.author_state,
            interaction,
        }
    }

    #[must_use]
    pub fn from_envelope(skill: &str, payload: HookEnvelopePayload) -> Self {
        let normalized = normalized_from_envelope(skill, payload);
        Self::from_normalized(normalized)
    }

    #[cfg(test)]
    #[must_use]
    pub(crate) fn from_test_envelope(skill: &str, payload: HookEnvelopePayload) -> Self {
        let normalized = hydrate_normalized_context(normalized_from_envelope(skill, payload));
        let interaction = HookInteraction::from_normalized(&normalized);
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
            interaction,
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
        &self.interaction.tool_name
    }

    #[must_use]
    pub fn tool_input(&self) -> &Value {
        &self.interaction.tool_input
    }

    #[must_use]
    pub fn tool_response(&self) -> &Value {
        &self.interaction.tool_response
    }

    #[must_use]
    pub fn command_text(&self) -> Option<&str> {
        self.tool
            .as_ref()
            .and_then(|tool| tool.input.command_text())
            .or_else(|| self.tool_input().get("command").and_then(Value::as_str))
    }

    /// # Errors
    /// Returns `CliError` when shell tokenization of the command text fails.
    pub fn command_words(&self) -> Result<&[String], CliError> {
        self.parsed_command()
            .map(|command| command.map_or(&[][..], ParsedCommand::words))
    }

    #[must_use]
    pub fn write_paths(&self) -> Vec<&Path> {
        if let Some(tool) = &self.tool {
            let paths = tool.input.write_paths();
            if !paths.is_empty() {
                return paths;
            }
        }

        let mut fallback_paths = Vec::new();
        if let Some(path) = self.tool_input().get("file_path").and_then(Value::as_str) {
            fallback_paths.push(Path::new(path));
        }
        if let Some(extra_paths) = self
            .tool_input()
            .get("file_paths")
            .and_then(Value::as_array)
        {
            fallback_paths.extend(extra_paths.iter().filter_map(Value::as_str).map(Path::new));
        }
        fallback_paths
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
        self.interaction
            .last_assistant_message
            .as_deref()
            .unwrap_or("")
    }

    #[must_use]
    pub fn stop_hook_active(&self) -> bool {
        self.interaction.stop_hook_active
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
        self.interaction.parsed_command.as_result()
    }
}

fn normalized_from_envelope(skill: &str, payload: HookEnvelopePayload) -> NormalizedHookContext {
    let raw = serde_json::to_value(&payload).unwrap_or(Value::Null);
    let tool_name = payload.tool_name;
    let input_raw = payload.tool_input;
    let response_raw = payload.tool_response;
    let tool = (!tool_name.is_empty()).then(|| {
        legacy_tool_context(
            &tool_name,
            input_raw,
            (!response_raw.is_null()).then_some(response_raw),
        )
    });

    NormalizedHookContext {
        event: NormalizedEvent::unspecified(),
        session: SessionContext {
            session_id: String::new(),
            cwd: None,
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

fn hydrate_normalized_context(mut normalized: NormalizedHookContext) -> NormalizedHookContext {
    normalized.session = hydrate_session(normalized.session);
    normalized
}

fn hydrate_session(mut session: SessionContext) -> SessionContext {
    if session.cwd.is_none() {
        session.cwd = Some(env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    }
    session
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn from_normalized_hydrates_missing_session_cwd() {
        let context = GuardContext::from_normalized(NormalizedHookContext {
            event: NormalizedEvent::Notification,
            session: SessionContext {
                session_id: String::new(),
                cwd: None,
                transcript_path: None,
            },
            tool: None,
            agent: None,
            skill: SkillContext::inactive(),
            raw: RawPayload::new(Value::Null),
        });

        assert_eq!(
            context.session.cwd,
            Some(env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
        );
    }
}
