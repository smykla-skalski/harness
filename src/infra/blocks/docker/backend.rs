use std::env;
use std::sync::Arc;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::compose::{BollardComposeOrchestrator, DockerComposeOrchestrator};
use crate::infra::blocks::{ComposeOrchestrator, ProcessExecutor};

use super::{BollardContainerRuntime, ContainerRuntime, DockerContainerRuntime};

pub const CONTAINER_RUNTIME_ENV: &str = "HARNESS_CONTAINER_RUNTIME";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ContainerRuntimeBackend {
    DockerCli,
    #[default]
    Bollard,
}

impl ContainerRuntimeBackend {
    fn parse(raw: &str) -> Result<Self, CliError> {
        match raw.trim() {
            "" | "bollard" => Ok(Self::Bollard),
            "docker-cli" => Ok(Self::DockerCli),
            other => Err(CliErrorKind::usage_error(format!(
                "invalid {CONTAINER_RUNTIME_ENV} value `{other}`; expected `bollard` or `docker-cli`"
            ))
            .into()),
        }
    }
}

#[derive(Clone)]
pub struct SelectedContainerBackends {
    pub backend: ContainerRuntimeBackend,
    pub container_runtime: Arc<dyn ContainerRuntime>,
    pub compose_orchestrator: Arc<dyn ComposeOrchestrator>,
}

/// Resolve the selected container backend from `HARNESS_CONTAINER_RUNTIME`.
///
/// # Errors
///
/// Returns `CliError` when the environment variable has an unsupported value.
pub fn container_backend_from_env() -> Result<ContainerRuntimeBackend, CliError> {
    env::var(CONTAINER_RUNTIME_ENV).map_or(Ok(ContainerRuntimeBackend::default()), |raw| {
        ContainerRuntimeBackend::parse(&raw)
    })
}

/// Build the selected container runtime implementation.
///
/// # Errors
///
/// Returns `CliError` when backend selection fails or the chosen runtime cannot initialize.
pub fn container_runtime_from_env(
    process: Arc<dyn ProcessExecutor>,
) -> Result<Arc<dyn ContainerRuntime>, CliError> {
    Ok(container_backends_from_env(process)?.container_runtime)
}

/// Build the matched regular-Docker and compose backends from one selector.
///
/// # Errors
///
/// Returns `CliError` when backend selection fails or the chosen backend cannot initialize.
pub fn container_backends_from_env(
    process: Arc<dyn ProcessExecutor>,
) -> Result<SelectedContainerBackends, CliError> {
    let backend = container_backend_from_env()?;
    match backend {
        ContainerRuntimeBackend::DockerCli => {
            let container_runtime: Arc<dyn ContainerRuntime> =
                Arc::new(DockerContainerRuntime::new(process.clone()));
            let compose_orchestrator: Arc<dyn ComposeOrchestrator> =
                Arc::new(DockerComposeOrchestrator::new(process));
            Ok(SelectedContainerBackends {
                backend,
                container_runtime,
                compose_orchestrator,
            })
        }
        ContainerRuntimeBackend::Bollard => {
            let container_runtime: Arc<dyn ContainerRuntime> =
                Arc::new(BollardContainerRuntime::new()?);
            let compose_orchestrator: Arc<dyn ComposeOrchestrator> =
                Arc::new(BollardComposeOrchestrator::new(container_runtime.clone()));
            Ok(SelectedContainerBackends {
                backend,
                container_runtime,
                compose_orchestrator,
            })
        }
    }
}
