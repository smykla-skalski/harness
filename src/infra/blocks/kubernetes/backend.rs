use std::env;
use std::sync::Arc;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::ProcessExecutor;

#[cfg(feature = "kubernetes")]
use super::KubeRuntime;
use super::{KUBERNETES_RUNTIME_ENV, KubectlRuntime, KubernetesRuntime};

/// Backend names `HARNESS_KUBERNETES_RUNTIME` accepts in this build.
#[cfg(feature = "kubernetes")]
const ACCEPTED_BACKENDS: &str = "`kube` or `kubectl-cli`";
#[cfg(not(feature = "kubernetes"))]
const ACCEPTED_BACKENDS: &str = "`kubectl-cli`, the only backend this build was compiled with";

/// The `Kube` variant stays in the enum whether or not the `kubernetes` feature
/// is on, because callers outside this block match on it exhaustively. Only the
/// backend it selects is conditional.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum KubernetesRuntimeBackend {
    #[cfg_attr(not(feature = "kubernetes"), default)]
    KubectlCli,
    #[cfg_attr(feature = "kubernetes", default)]
    Kube,
}

impl KubernetesRuntimeBackend {
    fn parse(raw: &str) -> Result<Self, CliError> {
        match raw.trim() {
            "" => Ok(Self::default()),
            #[cfg(feature = "kubernetes")]
            "kube" => Ok(Self::Kube),
            "kubectl-cli" => Ok(Self::KubectlCli),
            other => Err(CliErrorKind::usage_error(format!(
                "invalid {KUBERNETES_RUNTIME_ENV} value `{other}`; expected {ACCEPTED_BACKENDS}"
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
        #[cfg(feature = "kubernetes")]
        KubernetesRuntimeBackend::Kube => Arc::new(KubeRuntime::new()),
        #[cfg(not(feature = "kubernetes"))]
        KubernetesRuntimeBackend::Kube => {
            return Err(CliErrorKind::usage_error(format!(
                "the `kube` Kubernetes backend was compiled out; rebuild with the `kubernetes` feature or set {KUBERNETES_RUNTIME_ENV} to `kubectl-cli`"
            ))
            .into());
        }
    };
    Ok(SelectedKubernetesBackends {
        backend,
        kubernetes_runtime,
    })
}
