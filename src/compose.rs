use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde::Serialize;

use crate::errors::{CliError, CliErrorKind, cow};

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
        fs::write(path, yaml)?;
        Ok(())
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
        env.insert("KUMA_STORE_POSTGRES_HOST".into(), "postgres".into());
        env.insert("KUMA_STORE_POSTGRES_PORT".into(), "5432".into());
        env.insert("KUMA_STORE_POSTGRES_USER".into(), "kuma".into());
        env.insert("KUMA_STORE_POSTGRES_PASSWORD".into(), "kuma".into());
        env.insert("KUMA_STORE_POSTGRES_DB_NAME".into(), "kuma".into());
    }

    let (depends_on, restart) = if store_type == "postgres" {
        services.insert("postgres".into(), postgres_service(network_name));
        let mut deps = BTreeMap::new();
        deps.insert(
            "postgres".into(),
            ComposeDependsOnEntry {
                condition: "service_healthy".into(),
            },
        );
        (
            ComposeDependsOn::Conditional(deps),
            Some("on-failure".into()),
        )
    } else {
        (ComposeDependsOn::Simple(vec![]), None)
    };

    services.insert(
        cp_name.into(),
        ComposeService {
            image: image.into(),
            environment: env,
            ports: vec!["5681:5681".into(), "5678:5678".into()],
            depends_on,
            networks: vec![network_name.into()],
            command: cp_command(store_type),
            entrypoint: cp_entrypoint(store_type),
            restart,
            healthcheck: None,
        },
    );

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
    let (global_depends, global_restart) =
        postgres_depends(store_type, network_name, &mut services);

    if store_type == "postgres" {
        global_env.insert("KUMA_STORE_POSTGRES_HOST".into(), "postgres".into());
        global_env.insert("KUMA_STORE_POSTGRES_PORT".into(), "5432".into());
        global_env.insert("KUMA_STORE_POSTGRES_USER".into(), "kuma".into());
        global_env.insert("KUMA_STORE_POSTGRES_PASSWORD".into(), "kuma".into());
        global_env.insert("KUMA_STORE_POSTGRES_DB_NAME".into(), "kuma".into());
    }

    services.insert(
        global_name.into(),
        ComposeService {
            image: image.into(),
            environment: global_env,
            ports: vec!["5681:5681".into(), "5685:5685".into()],
            depends_on: global_depends,
            networks: vec![network_name.into()],
            command: cp_command(store_type),
            entrypoint: cp_entrypoint(store_type),
            restart: global_restart,
            healthcheck: None,
        },
    );

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

    services.insert(
        zone_name.into(),
        ComposeService {
            image: image.into(),
            environment: zone_env,
            ports: vec!["15681:5681".into(), "15678:5678".into()],
            depends_on: ComposeDependsOn::Simple(vec![global_name.into()]),
            networks: vec![network_name.into()],
            command: vec!["run".into()],
            entrypoint: None,
            restart: None,
            healthcheck: None,
        },
    );

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
    let (global_depends, global_restart) =
        postgres_depends(config.store_type, config.network_name, &mut services);

    if config.store_type == "postgres" {
        global_env.insert("KUMA_STORE_POSTGRES_HOST".into(), "postgres".into());
        global_env.insert("KUMA_STORE_POSTGRES_PORT".into(), "5432".into());
        global_env.insert("KUMA_STORE_POSTGRES_USER".into(), "kuma".into());
        global_env.insert("KUMA_STORE_POSTGRES_PASSWORD".into(), "kuma".into());
        global_env.insert("KUMA_STORE_POSTGRES_DB_NAME".into(), "kuma".into());
    }

    services.insert(
        config.global_name.into(),
        ComposeService {
            image: config.image.into(),
            environment: global_env,
            ports: vec!["5681:5681".into(), "5685:5685".into()],
            depends_on: global_depends,
            networks: vec![config.network_name.into()],
            command: cp_command(config.store_type),
            entrypoint: cp_entrypoint(config.store_type),
            restart: global_restart,
            healthcheck: None,
        },
    );

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

        services.insert(
            zone.name.into(),
            ComposeService {
                image: config.image.into(),
                environment: zone_env,
                ports: vec![format!("{port_offset}:5681"), format!("{xds_offset}:5678")],
                depends_on: ComposeDependsOn::Simple(vec![config.global_name.into()]),
                networks: vec![config.network_name.into()],
                command: vec!["run".into()],
                entrypoint: None,
                restart: None,
                healthcheck: None,
            },
        );
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

/// Build `depends_on` and restart policy for postgres-backed CP services.
fn postgres_depends(
    store_type: &str,
    network_name: &str,
    services: &mut BTreeMap<String, ComposeService>,
) -> (ComposeDependsOn, Option<String>) {
    if store_type != "postgres" {
        return (ComposeDependsOn::Simple(vec![]), None);
    }
    services.insert("postgres".into(), postgres_service(network_name));
    let mut deps = BTreeMap::new();
    deps.insert(
        "postgres".into(),
        ComposeDependsOnEntry {
            condition: "service_healthy".into(),
        },
    );
    (
        ComposeDependsOn::Conditional(deps),
        Some("on-failure".into()),
    )
}

fn postgres_service(network_name: &str) -> ComposeService {
    let mut env = BTreeMap::new();
    env.insert("POSTGRES_USER".into(), "kuma".into());
    env.insert("POSTGRES_PASSWORD".into(), "kuma".into());
    env.insert("POSTGRES_DB".into(), "kuma".into());
    ComposeService {
        image: "postgres:16-alpine".into(),
        environment: env,
        ports: vec!["5432:5432".into()],
        depends_on: ComposeDependsOn::Simple(vec![]),
        networks: vec![network_name.into()],
        command: vec![],
        entrypoint: None,
        restart: None,
        healthcheck: Some(ComposeHealthcheck {
            test: vec!["CMD-SHELL".into(), "pg_isready -U kuma -d kuma".into()],
            interval: "2s".into(),
            timeout: "5s".into(),
            retries: 10,
        }),
    }
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
