use serde::{Deserialize, Serialize};

use super::wire::{RemoteAttemptBinding, RemoteWireError, require_text};
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest};
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole};
use crate::task_board::TaskBoardExecutionPhase;

pub(crate) const REMOTE_CODEX_LAUNCH_SCHEMA_VERSION: u32 = 1;
pub(crate) const MAX_REMOTE_CODEX_PROMPT_BYTES: usize = 2 * 1024 * 1024;
const MAX_CAPABILITIES: usize = 256;
const MAX_LAUNCH_TEXT_BYTES: usize = 1_024;

/// Private, path-free Codex launch contract sealed into one remote offer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteCodexLaunchEnvelope {
    pub(crate) schema_version: u32,
    pub(crate) runtime: String,
    pub(crate) actor: String,
    pub(crate) prompt: String,
    pub(crate) mode: CodexRunMode,
    pub(crate) role: SessionRole,
    pub(crate) fallback_role: SessionRole,
    pub(crate) capabilities: Vec<String>,
    pub(crate) display_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) persona: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) task_id: Option<String>,
    pub(crate) board_item_id: String,
    pub(crate) workflow_execution_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) effort: Option<String>,
    pub(crate) allow_custom_model: bool,
}

impl RemoteCodexLaunchEnvelope {
    pub(crate) fn from_codex_request(
        runtime: &str,
        request: &CodexRunRequest,
    ) -> Result<Self, RemoteWireError> {
        let launch = Self {
            schema_version: REMOTE_CODEX_LAUNCH_SCHEMA_VERSION,
            runtime: runtime.to_owned(),
            actor: request
                .actor
                .clone()
                .ok_or(RemoteWireError::MissingField("actor"))?,
            prompt: request.prompt.clone(),
            mode: request.mode,
            role: request.role,
            fallback_role: request
                .fallback_role
                .ok_or(RemoteWireError::MissingField("fallback_role"))?,
            capabilities: request.capabilities.clone(),
            display_name: request
                .name
                .clone()
                .ok_or(RemoteWireError::MissingField("display_name"))?,
            persona: request.persona.clone(),
            task_id: request.task_id.clone(),
            board_item_id: request
                .board_item_id
                .clone()
                .ok_or(RemoteWireError::MissingField("board_item_id"))?,
            workflow_execution_id: request
                .workflow_execution_id
                .clone()
                .ok_or(RemoteWireError::MissingField("workflow_execution_id"))?,
            model: request.model.clone(),
            effort: request.effort.clone(),
            allow_custom_model: request.allow_custom_model,
        };
        launch.validate_common()?;
        Ok(launch)
    }

    pub(crate) fn validate(&self, binding: &RemoteAttemptBinding) -> Result<(), RemoteWireError> {
        self.validate_common()?;
        if self.workflow_execution_id != binding.execution_id
            || !phase_launch_matches(binding.phase, self)
        {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        Ok(())
    }

    pub(crate) fn codex_request(&self) -> CodexRunRequest {
        CodexRunRequest {
            actor: Some(self.actor.clone()),
            prompt: self.prompt.clone(),
            mode: self.mode,
            role: self.role,
            fallback_role: Some(self.fallback_role),
            capabilities: self.capabilities.clone(),
            name: Some(self.display_name.clone()),
            persona: self.persona.clone(),
            resume_thread_id: None,
            task_id: self.task_id.clone(),
            board_item_id: Some(self.board_item_id.clone()),
            workflow_execution_id: Some(self.workflow_execution_id.clone()),
            model: self.model.clone(),
            effort: self.effort.clone(),
            allow_custom_model: self.allow_custom_model,
        }
    }

    fn validate_common(&self) -> Result<(), RemoteWireError> {
        if self.schema_version != REMOTE_CODEX_LAUNCH_SCHEMA_VERSION {
            return Err(RemoteWireError::UnsupportedVersion);
        }
        for (name, value) in [
            ("runtime", self.runtime.as_str()),
            ("actor", self.actor.as_str()),
            ("prompt", self.prompt.as_str()),
            ("display_name", self.display_name.as_str()),
            ("board_item_id", self.board_item_id.as_str()),
            ("workflow_execution_id", self.workflow_execution_id.as_str()),
        ] {
            require_text(name, value)?;
        }
        if self.runtime != "codex"
            || self.actor != CONTROL_PLANE_ACTOR_ID
            || self.role != SessionRole::Leader
            || self.fallback_role != SessionRole::Worker
            || self.allow_custom_model
            || self.prompt.len() > MAX_REMOTE_CODEX_PROMPT_BYTES
            || self.capabilities.len() > MAX_CAPABILITIES
            || !bounded_text(&self.display_name)
            || !bounded_text(&self.board_item_id)
            || !bounded_text(&self.workflow_execution_id)
            || !bounded_optional(self.persona.as_deref())
            || !bounded_optional(self.task_id.as_deref())
            || !bounded_optional(self.model.as_deref())
            || !bounded_optional(self.effort.as_deref())
            || self.capabilities.iter().any(|value| !bounded_text(value))
        {
            return Err(RemoteWireError::MissingField("canonical_codex_launch"));
        }
        Ok(())
    }
}

fn phase_launch_matches(
    phase: TaskBoardExecutionPhase,
    launch: &RemoteCodexLaunchEnvelope,
) -> bool {
    match phase {
        TaskBoardExecutionPhase::Implementation => {
            launch.mode == CodexRunMode::WorkspaceWrite
                && launch.task_id.is_some()
                && launch.persona.is_none()
                && launch.model.is_none()
                && launch.effort.is_none()
        }
        TaskBoardExecutionPhase::Review | TaskBoardExecutionPhase::Evaluate => {
            launch.mode == CodexRunMode::Report
                && launch.task_id.is_none()
                && launch.persona.is_some()
        }
        _ => false,
    }
}

fn bounded_optional(value: Option<&str>) -> bool {
    value.is_none_or(bounded_text)
}

fn bounded_text(value: &str) -> bool {
    !value.trim().is_empty() && value.len() <= MAX_LAUNCH_TEXT_BYTES
}

#[cfg(test)]
pub(crate) fn test_codex_launch(
    phase: TaskBoardExecutionPhase,
    execution_id: &str,
    action_key: &str,
    prompt: &str,
) -> RemoteCodexLaunchEnvelope {
    let implementation = phase == TaskBoardExecutionPhase::Implementation;
    RemoteCodexLaunchEnvelope {
        schema_version: REMOTE_CODEX_LAUNCH_SCHEMA_VERSION,
        runtime: "codex".into(),
        actor: CONTROL_PLANE_ACTOR_ID.into(),
        prompt: prompt.into(),
        mode: if implementation {
            CodexRunMode::WorkspaceWrite
        } else {
            CodexRunMode::Report
        },
        role: SessionRole::Leader,
        fallback_role: SessionRole::Worker,
        capabilities: vec![
            "task-board".into(),
            format!("task-board:attempt:{action_key}"),
        ],
        display_name: format!("Remote Task Board {action_key}"),
        persona: (!implementation).then(|| "reviewer".into()),
        task_id: implementation.then(|| "task-remote".into()),
        board_item_id: "item-remote".into(),
        workflow_execution_id: execution_id.into(),
        model: None,
        effort: None,
        allow_custom_model: false,
    }
}
