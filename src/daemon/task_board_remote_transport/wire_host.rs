use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use super::wire::{RemoteWireError, require_canonical_time, require_text, require_version};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteHostAdvertisement {
    pub(crate) schema_version: u32,
    pub(crate) host_id: String,
    pub(crate) host_instance_id: String,
    pub(crate) protocol_version: u32,
    pub(crate) capabilities: BTreeSet<String>,
    pub(crate) runtimes: BTreeSet<String>,
    pub(crate) repositories: BTreeSet<String>,
    pub(crate) capacity: u32,
    pub(crate) active_assignments: u32,
    pub(crate) sent_at: String,
}

impl RemoteHostAdvertisement {
    pub(crate) fn validate(&self) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        require_text("host_id", &self.host_id)?;
        require_text("host_instance_id", &self.host_instance_id)?;
        require_canonical_time("sent_at", &self.sent_at)?;
        if self.protocol_version == 0
            || self.capacity == 0
            || self.active_assignments > self.capacity
        {
            return Err(RemoteWireError::InvalidCapacity);
        }
        if self
            .capabilities
            .iter()
            .any(|value| value.trim().is_empty())
            || self.runtimes.iter().any(|value| value.trim().is_empty())
            || self
                .repositories
                .iter()
                .any(|value| value.trim().is_empty())
            || self.capabilities.len() > 64
            || self.runtimes.len() > 64
            || self.repositories.len() > 256
            || self
                .capabilities
                .iter()
                .chain(&self.runtimes)
                .chain(&self.repositories)
                .any(|value| value.len() > 512)
        {
            return Err(RemoteWireError::MissingField("capability_or_runtime"));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteHeartbeatRequest {
    pub(crate) schema_version: u32,
    pub(crate) host_id: String,
    pub(crate) host_instance_id: String,
    pub(crate) active_assignments: u32,
    pub(crate) sent_at: String,
    pub(crate) request_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RemoteHeartbeatResponse {
    pub(crate) schema_version: u32,
    pub(crate) host_id: String,
    pub(crate) host_instance_id: String,
    pub(crate) accepted_at: String,
    pub(crate) next_heartbeat_deadline: String,
}

impl RemoteHeartbeatResponse {
    #[cfg(test)]
    pub(crate) fn validate(
        &self,
        expected: &RemoteHeartbeatRequest,
    ) -> Result<(), RemoteWireError> {
        require_version(self.schema_version)?;
        if self.host_id != expected.host_id || self.host_instance_id != expected.host_instance_id {
            return Err(RemoteWireError::ResultBindingMismatch);
        }
        require_canonical_time("accepted_at", &self.accepted_at)?;
        require_canonical_time("next_heartbeat_deadline", &self.next_heartbeat_deadline)
    }
}
