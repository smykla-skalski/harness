mod builders;
mod service;

use std::collections::BTreeMap;
use std::path::Path;

use serde::Serialize;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::write_text;

pub use builders::{GlobalTwoZonesConfig, ZoneConfig, global_two_zones, global_zone, single_zone};
pub use service::{ComposeDependsOn, ComposeDependsOnEntry, ComposeHealthcheck, ComposeService};

/// A Docker Compose network definition.
#[derive(Debug, Clone, Serialize)]
pub struct ComposeNetwork {
    pub driver: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ipam: Option<ComposeIpam>,
}

/// IPAM configuration for a compose network.
#[derive(Debug, Clone, Serialize)]
pub struct ComposeIpam {
    pub config: Vec<ComposeIpamConfig>,
}

/// A single subnet in IPAM configuration.
#[derive(Debug, Clone, Serialize)]
pub struct ComposeIpamConfig {
    pub subnet: String,
}

/// A complete Docker Compose file.
#[derive(Debug, Clone, Serialize)]
pub struct ComposeFile {
    pub services: BTreeMap<String, ComposeService>,
    pub networks: BTreeMap<String, ComposeNetwork>,
}

impl ComposeFile {
    /// Serialize to YAML string.
    ///
    /// # Errors
    /// Returns `CliError` on serialization failure.
    pub fn to_yaml(&self) -> Result<String, CliError> {
        serde_yml::to_string(self)
            .map_err(|e| CliErrorKind::serialize(format!("compose file: {e}")).into())
    }

    /// Write the compose file to disk.
    ///
    /// # Errors
    /// Returns `CliError` on write failure.
    pub fn write_to(&self, path: &Path) -> Result<(), CliError> {
        let yaml = self.to_yaml()?;
        write_text(path, &yaml)
    }
}

#[cfg(test)]
mod tests;
