use std::env;
use std::sync::Arc;

use harness_kernel::errors::{CliError, CliErrorKind};
use crate::infra::blocks::ProcessExecutor;

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
    match container_backend_from_env()? {
        ContainerRuntimeBackend::DockerCli => Ok(Arc::new(DockerContainerRuntime::new(process))),
        ContainerRuntimeBackend::Bollard => Ok(Arc::new(BollardContainerRuntime::new()?)),
    }
}
