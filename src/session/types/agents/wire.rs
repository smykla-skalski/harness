use serde::{Deserialize, Serialize};

use super::super::identity::AgentDescriptorId;
use super::AgentRegistration;
use crate::agents::kind::RuntimeKind;
use crate::agents::runtime::RuntimeCapabilities;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub(super) struct AgentRegistrationWire {
    session_agent_id: String,
    name: String,
    runtime: RuntimeKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    descriptor_id: Option<String>,
    role: super::SessionRole,
    #[serde(default)]
    capabilities: Vec<String>,
    joined_at: String,
    updated_at: String,
    status: super::AgentStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    runtime_session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    managed_agent_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    managed_agent_family: Option<super::ManagedAgentKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    last_activity_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    current_task_id: Option<String>,
    #[serde(default)]
    runtime_capabilities: RuntimeCapabilities,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    persona: Option<super::AgentPersona>,
}

impl From<&AgentRegistration> for AgentRegistrationWire {
    fn from(value: &AgentRegistration) -> Self {
        let descriptor_id = value.agent_descriptor_id();
        Self {
            session_agent_id: value.agent_id.clone(),
            name: value.name.clone(),
            runtime: value.runtime.clone(),
            descriptor_id: descriptor_id.map(AgentDescriptorId::into_inner),
            role: value.role,
            capabilities: value.capabilities.clone(),
            joined_at: value.joined_at.clone(),
            updated_at: value.updated_at.clone(),
            status: value.status.clone(),
            runtime_session_id: value.agent_session_id.clone(),
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
        let managed_agent = managed_agent_ref(value.managed_agent_id, value.managed_agent_family)?;
        Ok(AgentRegistration {
            agent_id: value.session_agent_id,
            name: value.name,
            runtime: value.runtime,
            role: value.role,
            capabilities: value.capabilities,
            joined_at: value.joined_at,
            updated_at: value.updated_at,
            status: value.status,
            agent_session_id: value.runtime_session_id,
            managed_agent,
            last_activity_at: value.last_activity_at,
            current_task_id: value.current_task_id,
            runtime_capabilities: value.runtime_capabilities,
            persona: value.persona,
        })
    }
}

fn managed_agent_ref(
    managed_agent_id: Option<String>,
    managed_agent_family: Option<super::ManagedAgentKind>,
) -> Result<Option<super::ManagedAgentRef>, String> {
    match (managed_agent_id, managed_agent_family) {
        (Some(id), Some(kind)) => Ok(Some(super::ManagedAgentRef::new(kind, id))),
        (None, None) => Ok(None),
        _ => Err("managed_agent_id and managed_agent_family must be provided together".to_string()),
    }
}
