use std::collections::BTreeMap;
use std::path::Path;

use serde::Serialize;

use crate::errors::{CliError, CliErrorKind, cow};
use crate::io::write_text;

#[cfg(test)]
use std::fs;

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
    fn is_empty(&self) -> bool {
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
            .map_err(|e| CliErrorKind::serialize(cow!("compose file: {e}")).into())
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

fn bridge_network(subnet: &str) -> ComposeNetwork {
    ComposeNetwork {
        driver: "bridge".into(),
        ipam: Some(ComposeIpam {
            config: vec![ComposeIpamConfig {
                subnet: subnet.into(),
            }],
        }),
    }
}

fn cp_env(kuma_mode: &str, store_type: &str) -> BTreeMap<String, String> {
    let mut env = BTreeMap::new();
    env.insert("KUMA_ENVIRONMENT".into(), "universal".into());
    env.insert("KUMA_MODE".into(), kuma_mode.into());
    env.insert("KUMA_STORE_TYPE".into(), store_type.into());
    env
}

fn postgres_cp_env(env: &mut BTreeMap<String, String>) {
    env.insert("KUMA_STORE_POSTGRES_HOST".into(), "postgres".into());
    env.insert("KUMA_STORE_POSTGRES_PORT".into(), "5432".into());
    env.insert("KUMA_STORE_POSTGRES_USER".into(), "kuma".into());
    env.insert("KUMA_STORE_POSTGRES_PASSWORD".into(), "kuma".into());
    env.insert("KUMA_STORE_POSTGRES_DB_NAME".into(), "kuma".into());
}

/// Generate a compose file for single-zone universal topology.
#[must_use]
pub fn single_zone(
    image: &str,
    network_name: &str,
    subnet: &str,
    store_type: &str,
    cp_name: &str,
) -> ComposeFile {
    let mut services = BTreeMap::new();
    let mut env = cp_env("zone", store_type);
    if store_type == "postgres" {
        postgres_cp_env(&mut env);
    }

    let (depends_on, is_postgres) = if store_type == "postgres" {
        services.insert("postgres".into(), postgres_service(network_name));
        let mut deps = BTreeMap::new();
        deps.insert(
            "postgres".into(),
            ComposeDependsOnEntry {
                condition: "service_healthy".into(),
            },
        );
        (ComposeDependsOn::Conditional(deps), true)
    } else {
        (ComposeDependsOn::Simple(vec![]), false)
    };

    let mut service = ComposeService::new(image, network_name)
        .with_environment(env)
        .with_ports(vec!["5681:5681".into(), "5678:5678".into()])
        .with_depends_on(depends_on)
        .with_command(cp_command(store_type));
    if let Some(ep) = cp_entrypoint(store_type) {
        service = service.with_entrypoint(ep);
    }
    if is_postgres {
        service = service.with_restart("on-failure");
    }
    services.insert(cp_name.into(), service);

    let mut networks = BTreeMap::new();
    networks.insert(network_name.into(), bridge_network(subnet));
    ComposeFile { services, networks }
}

/// Generate a compose file for global+zone universal topology.
#[must_use]
pub fn global_zone(
    image: &str,
    network_name: &str,
    subnet: &str,
    store_type: &str,
    global_name: &str,
    zone_name: &str,
    zone_label: &str,
) -> ComposeFile {
    let mut services = BTreeMap::new();

    let mut global_env = cp_env("global", store_type);
    let (global_depends, is_postgres) = postgres_depends(store_type, network_name, &mut services);

    if store_type == "postgres" {
        postgres_cp_env(&mut global_env);
    }

    let mut global_service = ComposeService::new(image, network_name)
        .with_environment(global_env)
        .with_ports(vec!["5681:5681".into(), "5685:5685".into()])
        .with_depends_on(global_depends)
        .with_command(cp_command(store_type));
    if let Some(ep) = cp_entrypoint(store_type) {
        global_service = global_service.with_entrypoint(ep);
    }
    if is_postgres {
        global_service = global_service.with_restart("on-failure");
    }
    services.insert(global_name.into(), global_service);

    let mut zone_env = cp_env("zone", "memory");
    zone_env.insert("KUMA_MULTIZONE_ZONE_NAME".into(), zone_label.into());
    zone_env.insert(
        "KUMA_MULTIZONE_ZONE_GLOBAL_ADDRESS".into(),
        format!("grpcs://{global_name}:5685"),
    );
    zone_env.insert(
        "KUMA_MULTIZONE_ZONE_KDS_TLS_SKIP_VERIFY".into(),
        "true".into(),
    );

    let zone_service = ComposeService::new(image, network_name)
        .with_environment(zone_env)
        .with_ports(vec!["15681:5681".into(), "15678:5678".into()])
        .with_depends_on(ComposeDependsOn::Simple(vec![global_name.into()]))
        .with_command(vec!["run".into()]);
    services.insert(zone_name.into(), zone_service);

    let mut networks = BTreeMap::new();
    networks.insert(network_name.into(), bridge_network(subnet));
    ComposeFile { services, networks }
}

/// Zone settings for multi-zone compose generation.
#[derive(Debug, Clone, Copy)]
pub struct ZoneConfig<'a> {
    pub name: &'a str,
    pub label: &'a str,
}

/// Config for global+two-zones universal topology.
#[derive(Debug, Clone, Copy)]
pub struct GlobalTwoZonesConfig<'a> {
    pub image: &'a str,
    pub network_name: &'a str,
    pub subnet: &'a str,
    pub store_type: &'a str,
    pub global_name: &'a str,
    pub zone1: ZoneConfig<'a>,
    pub zone2: ZoneConfig<'a>,
}

/// Generate a compose file for global+two-zones universal topology.
#[must_use]
pub fn global_two_zones(config: GlobalTwoZonesConfig<'_>) -> ComposeFile {
    let mut services = BTreeMap::new();

    let mut global_env = cp_env("global", config.store_type);
    let (global_depends, is_postgres) =
        postgres_depends(config.store_type, config.network_name, &mut services);

    if config.store_type == "postgres" {
        postgres_cp_env(&mut global_env);
    }

    let mut global_service = ComposeService::new(config.image, config.network_name)
        .with_environment(global_env)
        .with_ports(vec!["5681:5681".into(), "5685:5685".into()])
        .with_depends_on(global_depends)
        .with_command(cp_command(config.store_type));
    if let Some(ep) = cp_entrypoint(config.store_type) {
        global_service = global_service.with_entrypoint(ep);
    }
    if is_postgres {
        global_service = global_service.with_restart("on-failure");
    }
    services.insert(config.global_name.into(), global_service);

    for (i, zone) in [config.zone1, config.zone2].iter().enumerate() {
        let port_offset = u16::try_from(i).unwrap_or(0) * 10000 + 15681;
        let xds_offset = u16::try_from(i).unwrap_or(0) * 10000 + 15678;

        let mut zone_env = cp_env("zone", "memory");
        zone_env.insert("KUMA_MULTIZONE_ZONE_NAME".into(), zone.label.into());
        zone_env.insert(
            "KUMA_MULTIZONE_ZONE_GLOBAL_ADDRESS".into(),
            format!("grpcs://{}:5685", config.global_name),
        );
        zone_env.insert(
            "KUMA_MULTIZONE_ZONE_KDS_TLS_SKIP_VERIFY".into(),
            "true".into(),
        );

        let zone_service = ComposeService::new(config.image, config.network_name)
            .with_environment(zone_env)
            .with_ports(vec![
                format!("{port_offset}:5681"),
                format!("{xds_offset}:5678"),
            ])
            .with_depends_on(ComposeDependsOn::Simple(vec![config.global_name.into()]))
            .with_command(vec!["run".into()]);
        services.insert(zone.name.into(), zone_service);
    }

    let mut networks = BTreeMap::new();
    networks.insert(config.network_name.into(), bridge_network(config.subnet));
    ComposeFile { services, networks }
}

/// Command args for a CP service. Postgres needs migration before run.
fn cp_command(store_type: &str) -> Vec<String> {
    if store_type == "postgres" {
        vec!["kuma-cp migrate up && kuma-cp run".into()]
    } else {
        vec!["run".into()]
    }
}

/// Entrypoint override for CP services. Postgres needs sh to chain commands.
fn cp_entrypoint(store_type: &str) -> Option<Vec<String>> {
    if store_type == "postgres" {
        Some(vec!["sh".into(), "-c".into()])
    } else {
        None
    }
}

/// Build `depends_on` for postgres-backed CP services. Returns whether postgres is used.
fn postgres_depends(
    store_type: &str,
    network_name: &str,
    services: &mut BTreeMap<String, ComposeService>,
) -> (ComposeDependsOn, bool) {
    if store_type != "postgres" {
        return (ComposeDependsOn::Simple(vec![]), false);
    }
    services.insert("postgres".into(), postgres_service(network_name));
    let mut deps = BTreeMap::new();
    deps.insert(
        "postgres".into(),
        ComposeDependsOnEntry {
            condition: "service_healthy".into(),
        },
    );
    (ComposeDependsOn::Conditional(deps), true)
}

fn postgres_service(network_name: &str) -> ComposeService {
    let mut env = BTreeMap::new();
    env.insert("POSTGRES_USER".into(), "kuma".into());
    env.insert("POSTGRES_PASSWORD".into(), "kuma".into());
    env.insert("POSTGRES_DB".into(), "kuma".into());
    ComposeService::new("postgres:16-alpine", network_name)
        .with_environment(env)
        .with_ports(vec!["5432:5432".into()])
        .with_healthcheck(ComposeHealthcheck {
            test: vec!["CMD-SHELL".into(), "pg_isready -U kuma -d kuma".into()],
            interval: "2s".into(),
            timeout: "5s".into(),
            retries: 10,
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_zone_produces_valid_yaml() {
        let compose = single_zone(
            "kuma-cp:latest",
            "harness-net",
            "172.57.0.0/16",
            "memory",
            "cp",
        );
        let yaml = compose.to_yaml().unwrap();
        assert!(yaml.contains("kuma-cp:latest"));
        assert!(yaml.contains("harness-net"));
        assert!(yaml.contains("KUMA_ENVIRONMENT"));
        assert!(yaml.contains("5681:5681"));
        // Memory store should not produce a postgres service
        assert!(!yaml.contains("postgres"));
    }

    #[test]
    fn single_zone_with_postgres() {
        let compose = single_zone("kuma-cp:latest", "net", "172.57.0.0/16", "postgres", "cp");
        let yaml = compose.to_yaml().unwrap();
        assert!(yaml.contains("postgres"));
        assert!(yaml.contains("KUMA_STORE_POSTGRES_HOST"));
        assert!(compose.services.contains_key("postgres"));
    }

    #[test]
    fn global_zone_produces_both_services() {
        let compose = global_zone(
            "kuma-cp:latest",
            "net",
            "172.57.0.0/16",
            "memory",
            "global-cp",
            "zone-cp",
            "zone-1",
        );
        let yaml = compose.to_yaml().unwrap();
        assert!(yaml.contains("global-cp"));
        assert!(yaml.contains("zone-cp"));
        assert!(yaml.contains("KUMA_MODE: global"));
        assert!(yaml.contains("KUMA_MODE: zone"));
        assert!(yaml.contains("zone-1"));
        assert!(yaml.contains("grpcs://global-cp:5685"));
    }

    #[test]
    fn global_two_zones_produces_three_services() {
        let compose = global_two_zones(GlobalTwoZonesConfig {
            image: "kuma-cp:latest",
            network_name: "net",
            subnet: "172.57.0.0/16",
            store_type: "memory",
            global_name: "global-cp",
            zone1: ZoneConfig {
                name: "zone-1-cp",
                label: "zone-1",
            },
            zone2: ZoneConfig {
                name: "zone-2-cp",
                label: "zone-2",
            },
        });
        assert!(compose.services.contains_key("global-cp"));
        assert!(compose.services.contains_key("zone-1-cp"));
        assert!(compose.services.contains_key("zone-2-cp"));
        // zone ports should be offset
        let z1 = &compose.services["zone-1-cp"];
        assert!(z1.ports.contains(&"15681:5681".into()));
        let z2 = &compose.services["zone-2-cp"];
        assert!(z2.ports.contains(&"25681:5681".into()));
    }

    #[test]
    fn compose_file_deterministic_output() {
        let c1 = single_zone("img", "net", "172.57.0.0/16", "memory", "cp");
        let c2 = single_zone("img", "net", "172.57.0.0/16", "memory", "cp");
        assert_eq!(c1.to_yaml().unwrap(), c2.to_yaml().unwrap());
    }

    #[test]
    fn compose_file_writes_to_disk() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("docker-compose.yaml");
        let compose = single_zone("img", "net", "172.57.0.0/16", "memory", "cp");
        compose.write_to(&path).unwrap();
        let content = fs::read_to_string(&path).unwrap();
        assert!(content.contains("img"));
    }

    #[test]
    fn network_has_ipam_config() {
        let compose = single_zone("img", "harness-net", "172.57.0.0/16", "memory", "cp");
        let net = &compose.networks["harness-net"];
        let ipam = net.ipam.as_ref().unwrap();
        assert_eq!(ipam.config[0].subnet, "172.57.0.0/16");
    }
}
