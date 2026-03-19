use std::path::PathBuf;

use crate::hooks::protocol::payloads::HookEnvelopePayload;
use crate::kernel::skills::{SKILL_NEW, SKILL_RUN};
use crate::kernel::tooling::{ToolContext, legacy_tool_context};
use serde_json::Value;

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
    pub cwd: Option<PathBuf>,
    pub transcript_path: Option<PathBuf>,
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
            is_runner: skill == SKILL_RUN,
            is_author: skill == SKILL_NEW,
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

pub(crate) fn normalized_from_envelope(
    skill: &str,
    payload: HookEnvelopePayload,
) -> NormalizedHookContext {
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
