use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use compose_spec::Compose;

use super::{ComposeDependsOn, ComposeFile, ComposeHealthcheck, ComposeOrchestrator};
use crate::infra::blocks::{BlockError, ContainerConfig, ContainerPort, ContainerRuntime};
use crate::infra::exec::CommandResult;

const COMPOSE_PROJECT_LABEL: &str = "io.harness.compose-project";
const COMPOSE_SERVICE_LABEL: &str = "io.harness.compose-service";

/// Compose orchestration backed by `ContainerRuntime` instead of `docker compose`.
pub struct BollardComposeOrchestrator {
    docker: Arc<dyn ContainerRuntime>,
}

impl BollardComposeOrchestrator {
    #[must_use]
    pub fn new(docker: Arc<dyn ContainerRuntime>) -> Self {
        Self { docker }
    }

    fn load_compose_file(compose_file: &Path) -> Result<ComposeFile, BlockError> {
        let yaml = fs::read_to_string(compose_file)
            .map_err(|error| BlockError::new("compose", "read compose file", error))?;
        let compose = Compose::options()
            .from_yaml_str(&yaml)
            .map_err(|error| BlockError::new("compose", "parse compose file", error))?;
        compose
            .validate_all()
            .map_err(|error| BlockError::new("compose", "validate compose file", error))?;
        serde_yml::from_str(&yaml)
            .map_err(|error| BlockError::new("compose", "deserialize compose file", error))
    }

    fn parse_ports(ports: &[String]) -> Result<Vec<ContainerPort>, BlockError> {
        ports
            .iter()
            .map(|port| {
                let (host, container) = port.split_once(':').ok_or_else(|| {
                    BlockError::message(
                        "compose",
                        "parse ports",
                        format!("unsupported port `{port}`"),
                    )
                })?;
                let host = host.parse::<u16>().map_err(|error| {
                    BlockError::message(
                        "compose",
                        "parse ports",
                        format!("invalid host port `{host}`: {error}"),
                    )
                })?;
                let container = container.parse::<u16>().map_err(|error| {
                    BlockError::message(
                        "compose",
                        "parse ports",
                        format!("invalid container port `{container}`: {error}"),
                    )
                })?;
                Ok(ContainerPort::fixed(host, container))
            })
            .collect()
    }

    fn parse_duration(value: Option<&String>) -> Result<Option<Duration>, BlockError> {
        let Some(value) = value else {
            return Ok(None);
        };
        let seconds = value.strip_suffix('s').ok_or_else(|| {
            BlockError::message(
                "compose",
                "parse healthcheck duration",
                format!("unsupported duration `{value}`"),
            )
        })?;
        let seconds = seconds.parse::<u64>().map_err(|error| {
            BlockError::message(
                "compose",
                "parse healthcheck duration",
                format!("invalid duration `{value}`: {error}"),
            )
        })?;
        Ok(Some(Duration::from_secs(seconds)))
    }

    fn health_timeout(healthcheck: Option<&ComposeHealthcheck>) -> Result<Duration, BlockError> {
        let Some(healthcheck) = healthcheck else {
            return Ok(Duration::from_secs(0));
        };
        let interval =
            Self::parse_duration(healthcheck.interval.as_ref())?.unwrap_or(Duration::from_secs(1));
        let timeout =
            Self::parse_duration(healthcheck.timeout.as_ref())?.unwrap_or(Duration::from_secs(5));
        let start_period = Self::parse_duration(healthcheck.start_period.as_ref())?
            .unwrap_or(Duration::from_secs(0));
        let retries = healthcheck.retries.unwrap_or(1).max(1);
        Ok(start_period + timeout + interval.saturating_mul(retries))
    }

    fn project_networks(
        &self,
        compose: &ComposeFile,
        project_name: &str,
    ) -> Result<Vec<String>, BlockError> {
        let mut names = Vec::new();
        for (network_name, network) in &compose.networks {
            let subnet = network
                .ipam
                .as_ref()
                .and_then(|ipam| ipam.config.first())
                .map(|config| config.subnet.as_str())
                .ok_or_else(|| {
                    BlockError::message(
                        "compose",
                        "create networks",
                        format!("network `{network_name}` is missing an ipam subnet"),
                    )
                })?;
            let actual_name = format!("{project_name}_{network_name}");
            self.docker.create_network_labeled(
                &actual_name,
                subnet,
                &[(COMPOSE_PROJECT_LABEL.to_string(), project_name.to_string())],
            )?;
            names.push(actual_name);
        }
        Ok(names)
    }

    fn dependency_names(depends_on: &ComposeDependsOn) -> Vec<String> {
        match depends_on {
            ComposeDependsOn::Simple(entries) => entries.clone(),
            ComposeDependsOn::Conditional(entries) => entries.keys().cloned().collect(),
        }
    }

    fn topo_order(compose: &ComposeFile) -> Result<Vec<String>, BlockError> {
        let mut pending = compose.services.keys().cloned().collect::<BTreeSet<_>>();
        let mut started = BTreeSet::new();
        let mut order = Vec::with_capacity(pending.len());

        while !pending.is_empty() {
            let mut progressed = false;
            let current = pending.iter().cloned().collect::<Vec<_>>();
            for service_name in current {
                let Some(service) = compose.services.get(&service_name) else {
                    continue;
                };
                let deps = Self::dependency_names(&service.depends_on);
                if deps.iter().all(|dependency| started.contains(dependency)) {
                    pending.remove(&service_name);
                    started.insert(service_name.clone());
                    order.push(service_name);
                    progressed = true;
                }
            }
            if !progressed {
                return Err(BlockError::message(
                    "compose",
                    "dependency ordering",
                    "cyclic or unresolved depends_on graph",
                ));
            }
        }

        Ok(order)
    }

    fn start_service(
        &self,
        project_name: &str,
        service_name: &str,
        service: &super::ComposeService,
    ) -> Result<(), BlockError> {
        let network_name = service.networks.first().ok_or_else(|| {
            BlockError::message(
                "compose",
                "start service",
                format!("service `{service_name}` has no network"),
            )
        })?;
        let actual_network = format!("{project_name}_{network_name}");
        let container_name = format!("{project_name}-{service_name}-1");
        let ports = Self::parse_ports(&service.ports)?;
        let labels = vec![
            (COMPOSE_PROJECT_LABEL.to_string(), project_name.to_string()),
            (COMPOSE_SERVICE_LABEL.to_string(), service_name.to_string()),
        ];
        self.docker.run_detached(&ContainerConfig {
            image: service.image.clone(),
            name: container_name.clone(),
            network: actual_network,
            env: service
                .environment
                .iter()
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect(),
            ports,
            labels,
            entrypoint: service.entrypoint.clone(),
            restart_policy: service.restart.clone(),
            extra_args: vec![],
            command: service.command.clone(),
        })?;
        if service.healthcheck.is_some() {
            self.docker.wait_healthy(
                &container_name,
                Self::health_timeout(service.healthcheck.as_ref())?,
            )?;
        }
        Ok(())
    }

    fn down_project_internal(
        &self,
        project_name: &str,
        fallback_networks: &[String],
    ) -> Result<CommandResult, BlockError> {
        let label = format!("{COMPOSE_PROJECT_LABEL}={project_name}");
        let _removed = self.docker.remove_by_label(&label)?;
        let mut removed_networks = self.docker.remove_networks_by_label(&label)?;
        for network in fallback_networks {
            if removed_networks.contains(network) {
                continue;
            }
            self.docker.remove_network(network)?;
            removed_networks.push(network.clone());
        }
        Ok(CommandResult {
            args: vec![
                "compose".to_string(),
                "down".to_string(),
                project_name.to_string(),
            ],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }
}

impl ComposeOrchestrator for BollardComposeOrchestrator {
    fn up(
        &self,
        compose_file: &Path,
        project_name: &str,
        _wait_timeout: Duration,
    ) -> Result<CommandResult, BlockError> {
        let compose = Self::load_compose_file(compose_file)?;
        let _networks = self.project_networks(&compose, project_name)?;
        for service_name in Self::topo_order(&compose)? {
            let Some(service) = compose.services.get(&service_name) else {
                continue;
            };
            self.start_service(project_name, &service_name, service)?;
        }
        Ok(CommandResult {
            args: vec![
                "compose".to_string(),
                "up".to_string(),
                project_name.to_string(),
            ],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }

    fn down(&self, compose_file: &Path, project_name: &str) -> Result<CommandResult, BlockError> {
        let compose = Self::load_compose_file(compose_file)?;
        let fallback_networks = compose
            .networks
            .keys()
            .map(|network| format!("{project_name}_{network}"))
            .collect::<Vec<_>>();
        self.down_project_internal(project_name, &fallback_networks)
    }

    fn down_project(&self, project_name: &str) -> Result<CommandResult, BlockError> {
        self.down_project_internal(project_name, &[])
    }
}
