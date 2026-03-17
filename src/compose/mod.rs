mod builders;
mod service;

use std::collections::BTreeMap;
use std::path::Path;

use serde::Serialize;

use crate::errors::{CliError, CliErrorKind, cow};
use crate::io::write_text;

#[cfg(test)]
use std::fs;

pub use builders::{GlobalTwoZonesConfig, ZoneConfig, global_two_zones, global_zone, single_zone};
pub use service::{
    ComposeDependsOn, ComposeDependsOnEntry, ComposeHealthcheck, ComposeService,
};

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
