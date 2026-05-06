use serde::{Deserialize, Serialize};

use super::AgentRegistration;

/// Compatibility wire used while older session exports/state files may still
/// carry legacy identity field names. New serialization stays canonical-only;
/// delete the legacy decode branches once the minimum supported daemon/state
/// versions are canonical-only.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct AgentRegistrationWire {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    agent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    session_agent_id: Option<String>,
    name: String,
    runtime: crate::agents::kind::RuntimeKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    descriptor_id: Option<String>,
    role: super::SessionRole,
    #[serde(default)]
    capabilities: Vec<String>,
    joined_at: String,
    updated_at: String,
    status: super::AgentStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    agent_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    runtime_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    managed_agent: Option<super::ManagedAgentRef>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    managed_agent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    managed_agent_family: Option<super::ManagedAgentKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    last_activity_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    current_task_id: Option<String>,
    #[serde(default)]
    runtime_capabilities: crate::agents::runtime::RuntimeCapabilities,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    persona: Option<super::AgentPersona>,
}

impl From<&AgentRegistration> for AgentRegistrationWire {
    fn from(value: &AgentRegistration) -> Self {
        let descriptor_id = value.agent_descriptor_id();
        Self {
            agent_id: None,
            session_agent_id: Some(value.agent_id.clone()),
            name: value.name.clone(),
            runtime: value.runtime.clone(),
            descriptor_id: descriptor_id.map(|id| id.into_inner()),
            role: value.role,
            capabilities: value.capabilities.clone(),
            joined_at: value.joined_at.clone(),
            updated_at: value.updated_at.clone(),
            status: value.status.clone(),
            agent_session_id: None,
            runtime_session_id: value.agent_session_id.clone(),
            managed_agent: value.managed_agent.clone(),
            managed_agent_id: value
                .managed_agent
                .as_ref()
                .map(|managed| managed.id.clone()),
            managed_agent_family: value.managed_agent.as_ref().map(|managed| managed.kind),
            last_activity_at: value.last_activity_at.clone(),
            current_task_id: value.current_task_id.clone(),
            runtime_capabilities: value.runtime_capabilities.clone(),
            persona: value.persona.clone(),
        }
    }
}

impl Serialize for AgentRegistration {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        AgentRegistrationWire::from(self).serialize(serializer)
    }
}

impl TryFrom<AgentRegistrationWire> for AgentRegistration {
    type Error = String;

    fn try_from(value: AgentRegistrationWire) -> Result<Self, Self::Error> {
        let agent_id = compatible_required_value(
            value.agent_id,
            value.session_agent_id,
            "agent_id",
            "session_agent_id",
        )?;
        let agent_session_id = compatible_optional_value(
            value.agent_session_id,
            value.runtime_session_id,
            "agent_session_id",
            "runtime_session_id",
        )?;
        let managed_agent = compatible_managed_agent(
            value.managed_agent,
            value.managed_agent_id,
            value.managed_agent_family,
        )?;
        Ok(AgentRegistration {
            agent_id,
            name: value.name,
            runtime: value.runtime,
            role: value.role,
            capabilities: value.capabilities,
            joined_at: value.joined_at,
            updated_at: value.updated_at,
            status: value.status,
            agent_session_id,
            managed_agent,
            last_activity_at: value.last_activity_at,
            current_task_id: value.current_task_id,
            runtime_capabilities: value.runtime_capabilities,
            persona: value.persona,
        })
    }
}

fn compatible_required_value(
    legacy: Option<String>,
    canonical: Option<String>,
    legacy_name: &str,
    canonical_name: &str,
) -> Result<String, String> {
    compatible_optional_value(legacy, canonical, legacy_name, canonical_name)?
        .ok_or_else(|| format!("missing {legacy_name} or {canonical_name}"))
}

fn compatible_optional_value(
    legacy: Option<String>,
    canonical: Option<String>,
    legacy_name: &str,
    canonical_name: &str,
) -> Result<Option<String>, String> {
    match (legacy, canonical) {
        (Some(legacy), Some(canonical)) if legacy != canonical => {
            Err(format!("{canonical_name} does not match {legacy_name}"))
        }
        (Some(legacy), Some(_)) | (Some(legacy), None) => Ok(Some(legacy)),
        (None, Some(canonical)) => Ok(Some(canonical)),
        (None, None) => Ok(None),
    }
}

fn compatible_managed_agent(
    managed_agent: Option<super::ManagedAgentRef>,
    managed_agent_id: Option<String>,
    managed_agent_family: Option<super::ManagedAgentKind>,
) -> Result<Option<super::ManagedAgentRef>, String> {
    match (managed_agent, managed_agent_id, managed_agent_family) {
        (Some(managed_agent), Some(id), Some(kind)) => {
            if managed_agent.id != id || managed_agent.kind != kind {
                return Err(
                    "managed_agent does not match managed_agent_id/managed_agent_family"
                        .to_string(),
                );
            }
            Ok(Some(managed_agent))
        }
        (Some(managed_agent), None, None) => Ok(Some(managed_agent)),
        (None, Some(id), Some(kind)) => Ok(Some(super::ManagedAgentRef::new(kind, id))),
        (None, None, None) => Ok(None),
        _ => Err("managed_agent_id and managed_agent_family must be provided together".to_string()),
    }
}
