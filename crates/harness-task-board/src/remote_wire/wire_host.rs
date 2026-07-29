use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use super::wire::{RemoteWireError, require_canonical_time, require_text, require_version};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
#[derive(utoipa::ToSchema)]
pub struct RemoteHostAdvertisement {
    pub schema_version: u32,
    pub host_id: String,
    pub host_instance_id: String,
    pub protocol_version: u32,
    pub capabilities: BTreeSet<String>,
    pub runtimes: BTreeSet<String>,
    pub repositories: BTreeSet<String>,
    pub capacity: u32,
    pub active_assignments: u32,
    pub sent_at: String,
}

impl RemoteHostAdvertisement {
    /// # Errors
    /// Returns [`RemoteWireError`] if a required field is missing or
    /// oversized, or the advertised capacity is invalid.
    pub fn validate(&self) -> Result<(), RemoteWireError> {
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
