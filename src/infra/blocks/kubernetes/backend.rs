use std::env;
use std::sync::Arc;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::ProcessExecutor;

use super::{KUBERNETES_RUNTIME_ENV, KubeRuntime, KubectlRuntime, KubernetesRuntime};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum KubernetesRuntimeBackend {
    KubectlCli,
    #[default]
    Kube,
}

impl KubernetesRuntimeBackend {
    fn parse(raw: &str) -> Result<Self, CliError> {
        match raw.trim() {
            "" | "kube" => Ok(Self::Kube),
            "kubectl-cli" => Ok(Self::KubectlCli),
            other => Err(CliErrorKind::usage_error(format!(
                "invalid {KUBERNETES_RUNTIME_ENV} value `{other}`; expected `kube` or `kubectl-cli`"
            ))
            .into()),
        }
    }
}

#[derive(Clone)]
pub struct SelectedKubernetesBackends {
    pub backend: KubernetesRuntimeBackend,
    pub kubernetes_runtime: Arc<dyn KubernetesRuntime>,
}

/// Resolve the selected Kubernetes backend from `HARNESS_KUBERNETES_RUNTIME`.
///
/// # Errors
///
/// Returns `CliError` when the environment variable has an unsupported value.
pub fn kubernetes_backend_from_env() -> Result<KubernetesRuntimeBackend, CliError> {
    env::var(KUBERNETES_RUNTIME_ENV).map_or(Ok(KubernetesRuntimeBackend::default()), |raw| {
        KubernetesRuntimeBackend::parse(&raw)
    })
}

/// Build the selected Kubernetes runtime implementation.
///
/// # Errors
///
/// Returns `CliError` when backend selection fails.
pub fn kubernetes_runtime_from_env(
    process: Arc<dyn ProcessExecutor>,
) -> Result<Arc<dyn KubernetesRuntime>, CliError> {
    Ok(kubernetes_backends_from_env(process)?.kubernetes_runtime)
}

/// Build the matched Kubernetes backend from one selector.
///
/// # Errors
///
/// Returns `CliError` when backend selection fails.
pub fn kubernetes_backends_from_env(
    process: Arc<dyn ProcessExecutor>,
) -> Result<SelectedKubernetesBackends, CliError> {
    let backend = kubernetes_backend_from_env()?;
    let kubernetes_runtime: Arc<dyn KubernetesRuntime> = match backend {
        KubernetesRuntimeBackend::KubectlCli => Arc::new(KubectlRuntime::new(process)),
        KubernetesRuntimeBackend::Kube => Arc::new(KubeRuntime::new()),
    };
    Ok(SelectedKubernetesBackends {
        backend,
        kubernetes_runtime,
    })
}
