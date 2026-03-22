use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::infra::blocks::BlockError;
use crate::infra::exec::CommandResult;

#[cfg(test)]
mod fake;
#[cfg(feature = "compose")]
mod runtime_bollard;
#[cfg(feature = "compose")]
mod runtime_cli;
#[cfg(test)]
mod tests;

#[cfg(feature = "compose")]
pub use runtime_bollard::BollardComposeOrchestrator;
#[cfg(feature = "compose")]
pub use runtime_cli::DockerComposeOrchestrator;

#[cfg(test)]
pub use fake::FakeComposeOrchestrator;

/// Compose network settings for a rendered topology.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NetworkSpec {
    pub name: String,
    pub subnet: String,
}

/// A single `depends_on` edge between services.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceDependency {
    pub service_name: String,
    pub condition: Option<String>,
}

/// Healthcheck configuration for a compose service.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HealthcheckSpec {
    pub test: Vec<String>,
    pub interval_seconds: Option<u64>,
    pub timeout_seconds: Option<u64>,
    pub retries: Option<u32>,
    pub start_period_seconds: Option<u64>,
}

/// Generic compose service contract used by block-level topology builders.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServiceSpec {
    pub name: String,
    pub image: String,
    pub environment: BTreeMap<String, String>,
    pub ports: Vec<(u16, u16)>,
    pub command: Vec<String>,
    pub entrypoint: Option<Vec<String>>,
    pub depends_on: Vec<ServiceDependency>,
    pub healthcheck: Option<HealthcheckSpec>,
    pub restart: Option<String>,
}

/// A generic compose topology that can be rendered into a compose YAML file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ComposeTopology {
    pub project_name: String,
    pub network: NetworkSpec,
    pub services: Vec<ServiceSpec>,
}

/// Serialized Docker Compose file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ComposeFile {
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    services: BTreeMap<String, ComposeService>,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    networks: BTreeMap<String, ComposeNetwork>,
}

impl ComposeFile {
    /// Serialize the compose file to YAML.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if serialization fails.
    pub fn to_yaml(&self) -> Result<String, BlockError> {
        serde_yml::to_string(self)
            .map_err(|error| BlockError::new("compose", "serialize compose file", error))
    }

    /// Write the compose YAML to disk.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if serialization or file writing fails.
    pub fn write_to(&self, path: &Path) -> Result<(), BlockError> {
        let yaml = self.to_yaml()?;
        fs::write(path, yaml).map_err(|error| {
            BlockError::new("compose", &format!("write {}", path.display()), error)
        })
    }
}

impl ComposeTopology {
    /// Render this topology into a serializable compose file.
    #[must_use]
    pub fn to_compose_file(&self) -> ComposeFile {
        let services = self
            .services
            .iter()
            .map(|service| {
                (
                    service.name.clone(),
                    ComposeService::from_spec(service, &self.network.name),
                )
            })
            .collect::<BTreeMap<_, _>>();

        let networks = BTreeMap::from([(
            self.network.name.clone(),
            ComposeNetwork::bridge_with_subnet(&self.network.subnet),
        )]);

        ComposeFile { services, networks }
    }

    /// Serialize this topology directly to YAML.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if serialization fails.
    pub fn to_yaml(&self) -> Result<String, BlockError> {
        self.to_compose_file().to_yaml()
    }
}

/// Multi-container orchestration via docker compose.
pub trait ComposeOrchestrator: Send + Sync {
    /// Start a compose project from a file.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the compose command fails.
    fn up(
        &self,
        compose_file: &Path,
        project_name: &str,
        wait_timeout: Duration,
    ) -> Result<CommandResult, BlockError>;

    /// Stop a compose project and remove volumes.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the compose command fails.
    fn down(&self, compose_file: &Path, project_name: &str) -> Result<CommandResult, BlockError>;

    /// Stop a compose project by name only.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` if the compose command fails.
    fn down_project(&self, project_name: &str) -> Result<CommandResult, BlockError>;
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ComposeNetwork {
    driver: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    ipam: Option<ComposeIpam>,
}

impl ComposeNetwork {
    fn bridge_with_subnet(subnet: &str) -> Self {
        Self {
            driver: "bridge".to_string(),
            ipam: Some(ComposeIpam {
                config: vec![ComposeIpamConfig {
                    subnet: subnet.to_string(),
                }],
            }),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ComposeIpam {
    config: Vec<ComposeIpamConfig>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ComposeIpamConfig {
    subnet: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ComposeService {
    image: String,
    #[serde(default)]
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    environment: BTreeMap<String, String>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Vec::is_empty")]
    ports: Vec<String>,
    #[serde(default)]
    #[serde(skip_serializing_if = "ComposeDependsOn::is_empty")]
    depends_on: ComposeDependsOn,
    #[serde(default)]
    networks: Vec<String>,
    #[serde(default)]
    #[serde(skip_serializing_if = "Vec::is_empty")]
    command: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    entrypoint: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    restart: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    healthcheck: Option<ComposeHealthcheck>,
}

impl ComposeService {
    fn from_spec(spec: &ServiceSpec, network_name: &str) -> Self {
        Self {
            image: spec.image.clone(),
            environment: spec.environment.clone(),
            ports: spec
                .ports
                .iter()
                .map(|(host, container)| format!("{host}:{container}"))
                .collect(),
            depends_on: ComposeDependsOn::from_dependencies(&spec.depends_on),
            networks: vec![network_name.to_string()],
            command: spec.command.clone(),
            entrypoint: spec.entrypoint.clone(),
            restart: spec.restart.clone(),
            healthcheck: spec.healthcheck.as_ref().map(ComposeHealthcheck::from_spec),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(untagged)]
enum ComposeDependsOn {
    Simple(Vec<String>),
    Conditional(BTreeMap<String, ComposeDependsOnEntry>),
}

impl ComposeDependsOn {
    fn from_dependencies(dependencies: &[ServiceDependency]) -> Self {
        if dependencies.is_empty() {
            return Self::Simple(vec![]);
        }

        if dependencies
            .iter()
            .all(|dependency| dependency.condition.is_none())
        {
            return Self::Simple(
                dependencies
                    .iter()
                    .map(|dependency| dependency.service_name.clone())
                    .collect(),
            );
        }

        let entries = dependencies
            .iter()
            .map(|dependency| {
                (
                    dependency.service_name.clone(),
                    ComposeDependsOnEntry {
                        condition: dependency
                            .condition
                            .clone()
                            .unwrap_or_else(|| "service_started".to_string()),
                    },
                )
            })
            .collect();

        Self::Conditional(entries)
    }

    fn is_empty(&self) -> bool {
        match self {
            Self::Simple(entries) => entries.is_empty(),
            Self::Conditional(entries) => entries.is_empty(),
        }
    }
}

impl Default for ComposeDependsOn {
    fn default() -> Self {
        Self::Simple(vec![])
    }
}

impl Serialize for ComposeDependsOn {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Simple(entries) => entries.serialize(serializer),
            Self::Conditional(entries) => entries.serialize(serializer),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ComposeDependsOnEntry {
    condition: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct ComposeHealthcheck {
    test: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    interval: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    timeout: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    retries: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    start_period: Option<String>,
}

impl ComposeHealthcheck {
    fn from_spec(spec: &HealthcheckSpec) -> Self {
        Self {
            test: spec.test.clone(),
            interval: spec.interval_seconds.map(seconds_string),
            timeout: spec.timeout_seconds.map(seconds_string),
            retries: spec.retries,
            start_period: spec.start_period_seconds.map(seconds_string),
        }
    }
}

fn seconds_string(value: u64) -> String {
    format!("{value}s")
}
