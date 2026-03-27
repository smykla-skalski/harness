use std::path::PathBuf;

use crate::kernel::skills::{SKILL_CREATE, SKILL_OBSERVE, SKILL_RUN};
use crate::kernel::tooling::ToolContext;
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
    UserPromptSubmit,
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

/// Which skill is active, if any.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkillKind {
    None,
    Runner,
    Create,
    Observe,
}

/// Skill metadata carried through the hook engine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkillContext {
    pub active: bool,
    pub name: Option<String>,
    pub kind: SkillKind,
}

impl SkillContext {
    #[must_use]
    pub fn inactive() -> Self {
        Self {
            active: false,
            name: None,
            kind: SkillKind::None,
        }
    }

    #[must_use]
    pub fn from_skill_name(skill: &str) -> Self {
        let kind = match skill {
            SKILL_RUN => SkillKind::Runner,
            SKILL_CREATE => SkillKind::Create,
            SKILL_OBSERVE => SkillKind::Observe,
            _ => SkillKind::None,
        };
        Self {
            active: !skill.is_empty(),
            name: (!skill.is_empty()).then(|| skill.to_string()),
            kind,
        }
    }

    #[must_use]
    pub fn is_runner(&self) -> bool {
        self.kind == SkillKind::Runner
    }

    #[must_use]
    pub fn is_create(&self) -> bool {
        self.kind == SkillKind::Create
    }

    #[must_use]
    pub fn is_observe(&self) -> bool {
        self.kind == SkillKind::Observe
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
