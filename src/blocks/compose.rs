use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
#[cfg(feature = "compose")]
use std::sync::Arc;
use std::time::Duration;

use serde::Serialize;

use crate::blocks::BlockError;
#[cfg(feature = "compose")]
use crate::blocks::ProcessExecutor;
use crate::core_defs::CommandResult;

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
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
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

    #[must_use]
    pub fn services_len(&self) -> usize {
        self.services.len()
    }

    #[must_use]
    pub fn networks_len(&self) -> usize {
        self.networks.len()
    }

    #[must_use]
    pub fn contains_service(&self, name: &str) -> bool {
        self.services.contains_key(name)
    }

    #[must_use]
    pub fn contains_network(&self, name: &str) -> bool {
        self.networks.contains_key(name)
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

/// Production compose implementation backed by `docker compose`.
#[cfg(feature = "compose")]
pub struct DockerComposeOrchestrator {
    process: Arc<dyn ProcessExecutor>,
}

#[cfg(feature = "compose")]
impl DockerComposeOrchestrator {
    #[must_use]
    pub fn new(process: Arc<dyn ProcessExecutor>) -> Self {
        Self { process }
    }
}

#[cfg(feature = "compose")]
impl ComposeOrchestrator for DockerComposeOrchestrator {
    fn up(
        &self,
        compose_file: &Path,
        project_name: &str,
        wait_timeout: Duration,
    ) -> Result<CommandResult, BlockError> {
        let file_str = compose_file.to_string_lossy();
        let timeout_str = wait_timeout.as_secs().to_string();
        self.process.run_streaming(
            &[
                "docker",
                "compose",
                "-f",
                &file_str,
                "-p",
                project_name,
                "up",
                "-d",
                "--wait",
                "--wait-timeout",
                &timeout_str,
            ],
            None,
            None,
            &[0],
        )
    }

    fn down(&self, compose_file: &Path, project_name: &str) -> Result<CommandResult, BlockError> {
        let file_str = compose_file.to_string_lossy();
        self.process.run(
            &[
                "docker",
                "compose",
                "-f",
                &file_str,
                "-p",
                project_name,
                "down",
                "-v",
            ],
            None,
            None,
            &[0],
        )
    }

    fn down_project(&self, project_name: &str) -> Result<CommandResult, BlockError> {
        self.process.run(
            &["docker", "compose", "-p", project_name, "down", "-v"],
            None,
            None,
            &[0],
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct ComposeIpam {
    config: Vec<ComposeIpamConfig>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct ComposeIpamConfig {
    subnet: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct ComposeService {
    image: String,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    environment: BTreeMap<String, String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    ports: Vec<String>,
    #[serde(skip_serializing_if = "ComposeDependsOn::is_empty")]
    depends_on: ComposeDependsOn,
    networks: Vec<String>,
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

#[derive(Debug, Clone, PartialEq, Eq)]
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

impl Serialize for ComposeDependsOn {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Simple(entries) => entries.serialize(serializer),
            Self::Conditional(entries) => entries.serialize(serializer),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
struct ComposeDependsOnEntry {
    condition: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
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

#[cfg(test)]
use std::collections;
#[cfg(test)]
use std::sync;

#[cfg(test)]
#[derive(Debug, Default)]
pub struct FakeComposeOrchestrator {
    projects: sync::Mutex<collections::HashMap<String, bool>>,
}

#[cfg(test)]
impl FakeComposeOrchestrator {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }
}

#[cfg(test)]
impl ComposeOrchestrator for FakeComposeOrchestrator {
    fn up(
        &self,
        _compose_file: &Path,
        project_name: &str,
        _wait_timeout: Duration,
    ) -> Result<CommandResult, BlockError> {
        let mut projects = self.projects.lock().expect("lock poisoned");
        projects.insert(project_name.to_string(), true);
        Ok(CommandResult {
            args: vec!["docker".into(), "compose".into(), "up".into()],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }

    fn down(&self, _compose_file: &Path, project_name: &str) -> Result<CommandResult, BlockError> {
        let mut projects = self.projects.lock().expect("lock poisoned");
        projects.remove(project_name);
        Ok(CommandResult {
            args: vec!["docker".into(), "compose".into(), "down".into()],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }

    fn down_project(&self, project_name: &str) -> Result<CommandResult, BlockError> {
        let mut projects = self.projects.lock().expect("lock poisoned");
        projects.remove(project_name);
        Ok(CommandResult {
            args: vec!["docker".into(), "compose".into(), "down".into()],
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        })
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;
    use std::sync::Arc;

    use super::*;
    use crate::blocks::{
        FakeComposeOrchestrator, FakeProcessExecutor, FakeProcessMethod, FakeResponse,
    };

    fn success_result(args: &[&str]) -> CommandResult {
        CommandResult {
            args: args.iter().map(|arg| (*arg).to_string()).collect(),
            returncode: 0,
            stdout: String::new(),
            stderr: String::new(),
        }
    }

    fn sample_topology_with_service() -> ComposeTopology {
        ComposeTopology {
            project_name: "mesh".to_string(),
            network: NetworkSpec {
                name: "mesh-net".to_string(),
                subnet: "172.57.0.0/16".to_string(),
            },
            services: vec![ServiceSpec {
                name: "cp".to_string(),
                image: "kumahq/kuma-cp:latest".to_string(),
                environment: BTreeMap::from([("KUMA_MODE".to_string(), "zone".to_string())]),
                ports: vec![(5681, 5681), (5678, 5678)],
                command: vec!["run".to_string()],
                entrypoint: None,
                depends_on: vec![],
                healthcheck: Some(HealthcheckSpec {
                    test: vec!["CMD".to_string(), "true".to_string()],
                    interval_seconds: Some(5),
                    timeout_seconds: Some(5),
                    retries: Some(10),
                    start_period_seconds: Some(5),
                }),
                restart: Some("unless-stopped".to_string()),
            }],
        }
    }

    #[test]
    fn compose_topology_renders_compose_yaml() {
        let yaml = sample_topology_with_service()
            .to_yaml()
            .expect("expected compose yaml");

        for expected in [
            "services:",
            "cp:",
            "kumahq/kuma-cp:latest",
            "mesh-net",
            "172.57.0.0/16",
            "5681:5681",
            "start_period: '5s'",
        ] {
            assert!(yaml.contains(expected), "missing: {expected}");
        }
    }

    #[test]
    fn compose_dependencies_render_simple_list_when_unconditional() {
        let topology = ComposeTopology {
            project_name: "mesh".to_string(),
            network: NetworkSpec {
                name: "mesh-net".to_string(),
                subnet: "172.57.0.0/16".to_string(),
            },
            services: vec![ServiceSpec {
                name: "zone".to_string(),
                image: "img".to_string(),
                environment: BTreeMap::new(),
                ports: vec![],
                command: vec![],
                entrypoint: None,
                depends_on: vec![ServiceDependency {
                    service_name: "global".to_string(),
                    condition: None,
                }],
                healthcheck: None,
                restart: None,
            }],
        };

        let yaml = topology.to_yaml().expect("expected compose yaml");

        assert!(yaml.contains("depends_on:"));
        assert!(yaml.contains("- global"));
    }

    #[test]
    fn compose_dependencies_render_conditional_map_when_needed() {
        let topology = ComposeTopology {
            project_name: "mesh".to_string(),
            network: NetworkSpec {
                name: "mesh-net".to_string(),
                subnet: "172.57.0.0/16".to_string(),
            },
            services: vec![ServiceSpec {
                name: "zone".to_string(),
                image: "img".to_string(),
                environment: BTreeMap::new(),
                ports: vec![],
                command: vec![],
                entrypoint: None,
                depends_on: vec![ServiceDependency {
                    service_name: "postgres".to_string(),
                    condition: Some("service_healthy".to_string()),
                }],
                healthcheck: None,
                restart: None,
            }],
        };

        let yaml = topology.to_yaml().expect("expected compose yaml");

        assert!(yaml.contains("postgres:"));
        assert!(yaml.contains("condition: service_healthy"));
    }

    #[test]
    fn compose_file_writes_to_disk() {
        let topology = ComposeTopology {
            project_name: "mesh".to_string(),
            network: NetworkSpec {
                name: "mesh-net".to_string(),
                subnet: "172.57.0.0/16".to_string(),
            },
            services: vec![],
        };

        let tmp = tempfile::tempdir().expect("tempdir");
        let path = tmp.path().join("docker-compose.yaml");

        topology
            .to_compose_file()
            .write_to(&path)
            .expect("expected compose file write");

        let content = fs::read_to_string(&path).expect("read compose file");
        assert!(content.contains("networks:"));
        assert!(content.contains("mesh-net"));
    }

    #[test]
    fn docker_compose_orchestrator_up_uses_streaming_compose_command() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "compose".into(),
                "-f".into(),
                "/tmp/compose.yml".into(),
                "-p".into(),
                "mesh".into(),
                "up".into(),
                "-d".into(),
                "--wait".into(),
                "--wait-timeout".into(),
                "90".into(),
            ]),
            expected_method: Some(FakeProcessMethod::RunStreaming),
            result: Ok(success_result(&[
                "docker",
                "compose",
                "-f",
                "/tmp/compose.yml",
                "-p",
                "mesh",
                "up",
                "-d",
                "--wait",
                "--wait-timeout",
                "90",
            ])),
        }]));
        let orchestrator = DockerComposeOrchestrator::new(fake);

        let result = orchestrator
            .up(
                Path::new("/tmp/compose.yml"),
                "mesh",
                Duration::from_secs(90),
            )
            .expect("expected compose up to succeed");

        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn docker_compose_orchestrator_down_includes_volume_removal() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "compose".into(),
                "-f".into(),
                "/tmp/compose.yml".into(),
                "-p".into(),
                "mesh".into(),
                "down".into(),
                "-v".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(&[
                "docker",
                "compose",
                "-f",
                "/tmp/compose.yml",
                "-p",
                "mesh",
                "down",
                "-v",
            ])),
        }]));
        let orchestrator = DockerComposeOrchestrator::new(fake);

        let result = orchestrator
            .down(Path::new("/tmp/compose.yml"), "mesh")
            .expect("expected compose down to succeed");

        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn docker_compose_orchestrator_down_project_works_without_file() {
        let fake = Arc::new(FakeProcessExecutor::new(vec![FakeResponse {
            expected_program: "docker".to_string(),
            expected_args: Some(vec![
                "docker".into(),
                "compose".into(),
                "-p".into(),
                "mesh".into(),
                "down".into(),
                "-v".into(),
            ]),
            expected_method: Some(FakeProcessMethod::Run),
            result: Ok(success_result(&[
                "docker", "compose", "-p", "mesh", "down", "-v",
            ])),
        }]));
        let orchestrator = DockerComposeOrchestrator::new(fake);

        let result = orchestrator
            .down_project("mesh")
            .expect("expected compose down to succeed");

        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn fake_compose_orchestrator_tracks_project_state() {
        let orchestrator = FakeComposeOrchestrator::new();

        orchestrator
            .up(
                Path::new("/tmp/compose.yml"),
                "mesh",
                Duration::from_secs(60),
            )
            .expect("expected fake up to succeed");
        assert!(
            orchestrator
                .projects
                .lock()
                .expect("lock poisoned")
                .contains_key("mesh")
        );

        orchestrator
            .down_project("mesh")
            .expect("expected fake down to succeed");
        assert!(
            !orchestrator
                .projects
                .lock()
                .expect("lock poisoned")
                .contains_key("mesh")
        );
    }

    #[test]
    fn compose_types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}

        assert_send_sync::<ComposeFile>();
        assert_send_sync::<ComposeTopology>();
        assert_send_sync::<DockerComposeOrchestrator>();
        assert_send_sync::<FakeComposeOrchestrator>();
    }

    // -- Contract tests: fake satisfies the same invariants as production --

    mod contracts {
        use super::*;

        fn contract_up_then_down_succeeds(
            orchestrator: &dyn ComposeOrchestrator,
            compose_file: &Path,
            project_name: &str,
        ) {
            let up_result = orchestrator
                .up(compose_file, project_name, Duration::from_secs(60))
                .expect("compose up should succeed");
            assert_eq!(up_result.returncode, 0);
            let down_result = orchestrator
                .down(compose_file, project_name)
                .expect("compose down should succeed");
            assert_eq!(down_result.returncode, 0);
        }

        fn contract_down_project_is_idempotent(orchestrator: &dyn ComposeOrchestrator) {
            let result = orchestrator.down_project("nonexistent-contract-test-project");
            assert!(result.is_ok(), "down_project on missing project should not fail");
        }

        #[test]
        fn fake_satisfies_up_then_down() {
            contract_up_then_down_succeeds(
                &FakeComposeOrchestrator::new(),
                Path::new("/tmp/compose.yml"),
                "contract-test",
            );
        }

        #[test]
        fn fake_satisfies_down_project_is_idempotent() {
            contract_down_project_is_idempotent(&FakeComposeOrchestrator::new());
        }
    }
}
