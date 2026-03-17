use std::collections::BTreeMap;

use serde::Serialize;

/// A Docker Compose service definition.
#[derive(Debug, Clone, Serialize)]
pub struct ComposeService {
    pub image: String,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub environment: BTreeMap<String, String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub ports: Vec<String>,
    #[serde(skip_serializing_if = "ComposeDependsOn::is_empty")]
    pub depends_on: ComposeDependsOn,
    pub networks: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub command: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entrypoint: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub restart: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub healthcheck: Option<ComposeHealthcheck>,
}

impl ComposeService {
    /// Create a new service with sensible defaults.
    #[must_use]
    pub fn new(image: &str, network: &str) -> Self {
        Self {
            image: image.into(),
            environment: BTreeMap::new(),
            ports: Vec::new(),
            depends_on: ComposeDependsOn::Simple(vec![]),
            networks: vec![network.into()],
            command: Vec::new(),
            entrypoint: None,
            restart: None,
            healthcheck: None,
        }
    }

    #[must_use]
    pub fn with_environment(mut self, env: BTreeMap<String, String>) -> Self {
        self.environment = env;
        self
    }

    #[must_use]
    pub fn with_ports(mut self, ports: Vec<String>) -> Self {
        self.ports = ports;
        self
    }

    #[must_use]
    pub fn with_depends_on(mut self, depends_on: ComposeDependsOn) -> Self {
        self.depends_on = depends_on;
        self
    }

    #[must_use]
    pub fn with_command(mut self, command: Vec<String>) -> Self {
        self.command = command;
        self
    }

    #[must_use]
    pub fn with_entrypoint(mut self, entrypoint: Vec<String>) -> Self {
        self.entrypoint = Some(entrypoint);
        self
    }

    #[must_use]
    pub fn with_restart(mut self, restart: &str) -> Self {
        self.restart = Some(restart.into());
        self
    }

    #[must_use]
    pub fn with_healthcheck(mut self, healthcheck: ComposeHealthcheck) -> Self {
        self.healthcheck = Some(healthcheck);
        self
    }
}

/// Compose `depends_on` - either a simple list or a map with conditions.
#[derive(Debug, Clone)]
pub enum ComposeDependsOn {
    Simple(Vec<String>),
    Conditional(BTreeMap<String, ComposeDependsOnEntry>),
}

impl ComposeDependsOn {
    pub(crate) fn is_empty(&self) -> bool {
        match self {
            Self::Simple(v) => v.is_empty(),
            Self::Conditional(m) => m.is_empty(),
        }
    }

    /// Check if a service name is present in the dependency list.
    #[must_use]
    pub fn contains(&self, name: &str) -> bool {
        match self {
            Self::Simple(v) => v.iter().any(|s| s == name),
            Self::Conditional(m) => m.contains_key(name),
        }
    }
}

impl Serialize for ComposeDependsOn {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Simple(v) => v.serialize(serializer),
            Self::Conditional(m) => m.serialize(serializer),
        }
    }
}

/// Condition entry for conditional `depends_on`.
#[derive(Debug, Clone, Serialize)]
pub struct ComposeDependsOnEntry {
    pub condition: String,
}

/// Compose healthcheck definition.
#[derive(Debug, Clone, Serialize)]
pub struct ComposeHealthcheck {
    pub test: Vec<String>,
    pub interval: String,
    pub timeout: String,
    pub retries: u32,
}
