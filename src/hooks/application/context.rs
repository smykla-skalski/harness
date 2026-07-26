use std::path::Path;

use serde_json::Value;

use crate::hooks::protocol::context::{
    AgentContext, NormalizedEvent, NormalizedHookContext, SessionContext, SkillContext,
};
use crate::hooks::protocol::payloads::{AskUserAnswer, AskUserQuestionPrompt, HookEnvelopePayload};
use harness_kernel::kernel::tooling::ToolContext;

mod hydration;
mod interaction;

use self::hydration::hydrate_normalized_context;
pub(crate) use self::hydration::prepare_normalized_context;
use self::interaction::{
    HookInteraction, deserialize_value_list, normalized_from_envelope, render_tool_response_text,
};
#[path = "context/command.rs"]
mod command;

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
    interaction: HookInteraction,
}

impl GuardContext {
    #[must_use]
    pub fn from_normalized(normalized: NormalizedHookContext) -> Self {
        let normalized = hydrate_normalized_context(normalized);
        let interaction = HookInteraction::from_normalized(&normalized);
        Self {
            event: normalized.event,
            session: normalized.session,
            tool: normalized.tool,
            agent: normalized.agent,
            skill: normalized.skill,
            interaction,
        }
    }

    #[must_use]
    pub fn from_envelope(skill: &str, payload: HookEnvelopePayload) -> Self {
        let normalized = normalized_from_envelope(skill, payload);
        Self::from_normalized(normalized)
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
}

#[cfg(test)]
mod tests;
