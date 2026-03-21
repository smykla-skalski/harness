use std::borrow::Cow;
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::kernel::topology::{ClusterSpec, Platform};

#[path = "runtime/access.rs"]
mod access;
#[path = "runtime/kubernetes.rs"]
mod kubernetes;
#[path = "runtime/profile.rs"]
mod profile;
#[path = "runtime/universal.rs"]
mod universal;

pub(crate) use access::{ControlPlaneAccess, XdsAccess};
use kubernetes::KubernetesRuntime;
#[cfg(test)]
pub(crate) use profile::profile_platform;
use universal::UniversalRuntime;

/// Borrowed runtime access for the tracked cluster.
#[derive(Debug, Clone, Copy, PartialEq)]
#[non_exhaustive]
pub enum ClusterRuntime<'a> {
    Kubernetes(KubernetesRuntime<'a>),
    Universal(UniversalRuntime<'a>),
}

impl<'a> ClusterRuntime<'a> {
    /// Build runtime access from a persisted cluster spec.
    #[must_use]
    pub fn from_spec(spec: &'a ClusterSpec) -> Self {
        match spec.platform {
            Platform::Kubernetes => Self::Kubernetes(KubernetesRuntime::from_spec(spec)),
            Platform::Universal => Self::Universal(UniversalRuntime::from_spec(spec)),
        }
    }

    #[must_use]
    pub const fn platform(&self) -> Platform {
        match self {
            Self::Kubernetes(_) => Platform::Kubernetes,
            Self::Universal(_) => Platform::Universal,
        }
    }

    /// Resolve a kubeconfig path when the runtime is Kubernetes.
    ///
    /// # Errors
    /// Returns `CliError` when kubeconfig resolution is not valid for this runtime.
    pub fn resolve_kubeconfig(
        &self,
        explicit: Option<&'a str>,
        cluster: Option<&str>,
    ) -> Result<Cow<'a, Path>, CliError> {
        match self {
            Self::Kubernetes(runtime) => runtime.resolve_kubeconfig(explicit, cluster),
            Self::Universal(_) => Err(CliErrorKind::missing_run_context_value(
                "kubeconfig (universal mode does not use kubeconfig - use CP API instead)",
            )
            .into()),
        }
    }

    /// Resolve control plane access when the runtime is universal.
    ///
    /// # Errors
    /// Returns `CliError` when control plane access is not valid for this runtime.
    pub fn control_plane_access(&self) -> Result<ControlPlaneAccess<'a>, CliError> {
        match self {
            Self::Universal(runtime) => runtime.control_plane(),
            Self::Kubernetes(_) => {
                Err(CliErrorKind::missing_run_context_value("cp_api_url").into())
            }
        }
    }

    /// Resolve XDS access when the runtime is universal.
    ///
    /// # Errors
    /// Returns `CliError` when the runtime is not universal or the endpoint is incomplete.
    pub fn xds_access(&self) -> Result<XdsAccess<'a>, CliError> {
        match self {
            Self::Universal(runtime) => runtime.xds(),
            Self::Kubernetes(_) => {
                Err(CliErrorKind::missing_run_context_value("container_ip").into())
            }
        }
    }

    /// Resolve the universal Docker network name.
    ///
    /// # Errors
    /// Returns `CliError` when the runtime is not universal or no network is recorded.
    pub fn docker_network(&self) -> Result<&'a str, CliError> {
        match self {
            Self::Universal(runtime) => runtime.docker_network(),
            Self::Kubernetes(_) => {
                Err(CliErrorKind::missing_run_context_value("docker_network").into())
            }
        }
    }

    /// Resolve a tracked member name to the actual container name.
    #[must_use]
    pub fn resolve_container_name(&self, requested: &'a str) -> Cow<'a, str> {
        match self {
            Self::Universal(runtime) => runtime.resolve_container_name(requested),
            Self::Kubernetes(_) => Cow::Borrowed(requested),
        }
    }

    /// Resolve the image used for ad-hoc universal service containers.
    ///
    /// # Errors
    /// Returns `CliError` when the runtime is not universal or image derivation fails.
    pub fn service_image(&self, explicit: Option<&'a str>) -> Result<Cow<'a, str>, CliError> {
        match self {
            Self::Universal(runtime) => runtime.service_image(explicit),
            Self::Kubernetes(_) => Err(CliErrorKind::usage_error(
                "service is only available for universal runs",
            )
            .into()),
        }
    }
}

/// Resolve a run profile to a runtime platform when no cluster spec exists yet.
#[cfg(test)]
mod tests;
