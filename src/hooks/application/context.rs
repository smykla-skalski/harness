use std::borrow::Cow;
use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::authoring::AuthorWorkflowState;
use crate::errors::CliError;
use crate::hooks::protocol::context::{
    AgentContext, NormalizedEvent, NormalizedHookContext, SessionContext, SkillContext,
};
use crate::hooks::protocol::payloads::{AskUserAnswer, AskUserQuestionPrompt, HookEnvelopePayload};
use crate::kernel::command_intent::ParsedCommand;
use crate::kernel::tooling::ToolContext;
use crate::run::context::RunContext;
use crate::run::workflow::RunnerWorkflowState;

mod hydration;
mod interaction;

pub(crate) use self::hydration::prepare_normalized_context;
use self::hydration::{HydratedHookState, hydrate_normalized_context};
use self::interaction::{
    HookInteraction, deserialize_value_list, normalized_from_envelope, render_tool_response_text,
};

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
        self.interaction.parsed_command()
    }
}

#[cfg(test)]
mod tests;
