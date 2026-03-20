use std::borrow::Cow;
use std::path::Path;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::defaults;
use crate::kernel::topology::{ClusterSpec, Platform};

/// Borrowed access details for the universal control plane API.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlPlaneAccess<'a> {
    pub addr: Cow<'a, str>,
    pub admin_token: Option<&'a str>,
}

/// Borrowed access details for the universal XDS endpoint.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct XdsAccess<'a> {
    pub ip: &'a str,
    pub port: u16,
}

/// Borrowed Kubernetes runtime details for a tracked run.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct KubernetesRuntime<'a> {
    spec: &'a ClusterSpec,
}

impl<'a> KubernetesRuntime<'a> {
    fn from_spec(spec: &'a ClusterSpec) -> Self {
        Self { spec }
    }

    /// Resolve the effective kubeconfig for an operation.
    ///
    /// # Errors
    /// Returns `CliError` when the requested cluster is not tracked.
    pub fn resolve_kubeconfig(
        self,
        explicit: Option<&'a str>,
        cluster: Option<&str>,
    ) -> Result<Cow<'a, Path>, CliError> {
        if let Some(path) = explicit {
            return Ok(Cow::Borrowed(Path::new(path)));
        }
        if let Some(cluster_name) = cluster {
            return self
                .spec
                .member(cluster_name)
                .map(|member| Cow::Borrowed(Path::new(member.kubeconfig.as_str())))
                .ok_or_else(|| CliErrorKind::missing_run_context_value("kubeconfig").into());
        }
        Ok(Cow::Borrowed(Path::new(self.spec.primary_kubeconfig())))
    }
}

/// Borrowed universal runtime details for a tracked run.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UniversalRuntime<'a> {
    spec: &'a ClusterSpec,
}

impl<'a> UniversalRuntime<'a> {
    fn from_spec(spec: &'a ClusterSpec) -> Self {
        Self { spec }
    }

    /// Resolve a tracked member name to the underlying container name.
    #[must_use]
    pub fn resolve_container_name(self, requested: &'a str) -> Cow<'a, str> {
        self.spec.resolve_container_name(requested)
    }

    /// Docker network for the universal topology.
    ///
    /// # Errors
    /// Returns `CliError` when the network is unavailable.
    pub fn docker_network(self) -> Result<&'a str, CliError> {
        self.spec
            .docker_network
            .as_deref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("docker_network").into())
    }

    /// Resolve control plane access for the universal runtime.
    ///
    /// # Errors
    /// Returns `CliError` when the control plane endpoint is unavailable.
    pub fn control_plane(self) -> Result<ControlPlaneAccess<'a>, CliError> {
        let Some((ip, port)) = self.spec.primary_api_parts() else {
            return Err(CliErrorKind::missing_run_context_value("cp_api_url").into());
        };
        Ok(ControlPlaneAccess {
            addr: Cow::Owned(format!("http://{ip}:{port}")),
            admin_token: self.spec.admin_token(),
        })
    }

    /// Resolve XDS access for the universal runtime.
    ///
    /// # Errors
    /// Returns `CliError` when the XDS endpoint is unavailable.
    pub fn xds(self) -> Result<XdsAccess<'a>, CliError> {
        let member = self.spec.primary_member();
        let Some(ip) = member.container_ip.as_deref() else {
            return Err(CliErrorKind::missing_run_context_value("container_ip").into());
        };
        Ok(XdsAccess {
            ip,
            port: member.xds_port.unwrap_or(defaults::XDS_PORT),
        })
    }

    /// Resolve the image used for ad-hoc universal service containers.
    ///
    /// # Errors
    /// Returns `CliError` when no image can be determined.
    pub fn service_image(self, explicit: Option<&'a str>) -> Result<Cow<'a, str>, CliError> {
        if let Some(image) = explicit {
            return Ok(Cow::Borrowed(image));
        }
        let Some(cp_image) = self.spec.cp_image.as_deref() else {
            return Err(CliErrorKind::usage_error(
                "service image is required (pass --image or ensure cluster has cp_image set)",
            )
            .into());
        };
        if let Ok(image) = defaults::derive_universal_service_image(cp_image) {
            return Ok(Cow::Owned(image));
        }
        Err(CliErrorKind::usage_error(format!(
            "cannot derive service image from cp_image '{cp_image}' - pass --image explicitly"
        ))
        .into())
    }
}

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
#[must_use]
#[cfg(test)]
pub fn profile_platform(profile: &str) -> Platform {
    if profile == "universal" || profile.starts_with("universal-") {
        return Platform::Universal;
    }
    Platform::Kubernetes
}

#[cfg(test)]
mod tests;
