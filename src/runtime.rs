use std::collections::HashMap;
use std::path::PathBuf;

use crate::cluster::{ClusterSpec, Platform};
use crate::context::RunAggregate;
use crate::errors::{CliError, CliErrorKind};

/// Access details for the universal control plane API.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlPlaneAccess {
    pub addr: String,
    pub admin_token: Option<String>,
}

/// Access details for the universal XDS endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct XdsAccess {
    pub ip: String,
    pub port: u16,
}

/// Kubernetes runtime details for a tracked run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KubernetesRuntime {
    default_kubeconfig: PathBuf,
    kubeconfigs: HashMap<String, PathBuf>,
}

impl KubernetesRuntime {
    fn from_spec(spec: &ClusterSpec) -> Self {
        let kubeconfigs = spec
            .members
            .iter()
            .map(|member| (member.name.clone(), PathBuf::from(&member.kubeconfig)))
            .collect();
        Self {
            default_kubeconfig: PathBuf::from(spec.primary_kubeconfig()),
            kubeconfigs,
        }
    }

    /// Resolve the effective kubeconfig for an operation.
    ///
    /// # Errors
    /// Returns `CliError` when the requested cluster is not tracked.
    pub fn resolve_kubeconfig(
        &self,
        explicit: Option<&str>,
        cluster: Option<&str>,
    ) -> Result<PathBuf, CliError> {
        if let Some(path) = explicit {
            return Ok(PathBuf::from(path));
        }
        if let Some(cluster_name) = cluster {
            return self
                .kubeconfigs
                .get(cluster_name)
                .cloned()
                .ok_or_else(|| CliErrorKind::missing_run_context_value("kubeconfig").into());
        }
        Ok(self.default_kubeconfig.clone())
    }
}

/// Universal runtime details for a tracked run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UniversalRuntime {
    control_plane: Option<ControlPlaneAccess>,
    xds: Option<XdsAccess>,
    docker_network: Option<String>,
    cp_image: Option<String>,
    member_containers: HashMap<String, String>,
}

impl UniversalRuntime {
    fn from_spec(spec: &ClusterSpec) -> Self {
        let control_plane = spec.primary_api_url().map(|addr| ControlPlaneAccess {
            addr,
            admin_token: spec.admin_token.clone(),
        });
        let xds = spec
            .primary_member()
            .container_ip
            .clone()
            .map(|ip| XdsAccess {
                ip,
                port: spec.primary_member().xds_port.unwrap_or(5678),
            });
        let member_containers = spec
            .members
            .iter()
            .map(|member| {
                let container = if spec.is_compose_managed() {
                    let project = format!(
                        "harness-{}",
                        spec.members
                            .first()
                            .map_or("default", |item| item.name.as_str())
                    );
                    format!("{project}-{}-1", member.name)
                } else {
                    member.name.clone()
                };
                (member.name.clone(), container)
            })
            .collect();

        Self {
            control_plane,
            xds,
            docker_network: spec.docker_network.clone(),
            cp_image: spec.cp_image.clone(),
            member_containers,
        }
    }

    /// Resolve a tracked member name to the underlying container name.
    #[must_use]
    pub fn resolve_container_name(&self, requested: &str) -> String {
        self.member_containers
            .get(requested)
            .cloned()
            .unwrap_or_else(|| requested.to_string())
    }

    /// Docker network for the universal topology.
    ///
    /// # Errors
    /// Returns `CliError` when the network is unavailable.
    pub fn docker_network(&self) -> Result<&str, CliError> {
        self.docker_network
            .as_deref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("docker_network").into())
    }

    /// Resolve control plane access for the universal runtime.
    ///
    /// # Errors
    /// Returns `CliError` when the control plane endpoint is unavailable.
    pub fn control_plane(&self) -> Result<&ControlPlaneAccess, CliError> {
        self.control_plane
            .as_ref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("cp_api_url").into())
    }

    /// Resolve XDS access for the universal runtime.
    ///
    /// # Errors
    /// Returns `CliError` when the XDS endpoint is unavailable.
    pub fn xds(&self) -> Result<&XdsAccess, CliError> {
        self.xds
            .as_ref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("container_ip").into())
    }

    /// Resolve the image used for ad-hoc universal service containers.
    ///
    /// # Errors
    /// Returns `CliError` when no image can be determined.
    pub fn service_image(&self, explicit: Option<&str>) -> Result<String, CliError> {
        if let Some(image) = explicit {
            return Ok(image.to_string());
        }
        let Some(cp_image) = self.cp_image.as_deref() else {
            return Err(CliErrorKind::usage_error(
                "service image is required (pass --image or ensure cluster has cp_image set)",
            )
            .into());
        };
        if cp_image.contains("kuma-cp") {
            return Ok(cp_image.replace("kuma-cp", "kuma-universal"));
        }
        Err(CliErrorKind::usage_error(format!(
            "cannot derive service image from cp_image '{cp_image}' - pass --image explicitly"
        ))
        .into())
    }
}

/// Runtime access for the tracked cluster.
#[derive(Debug, Clone, PartialEq, Eq)]
#[non_exhaustive]
pub enum ClusterRuntime {
    Kubernetes(KubernetesRuntime),
    Universal(UniversalRuntime),
}

impl ClusterRuntime {
    /// Build runtime access from a run aggregate.
    ///
    /// # Errors
    /// Returns `CliError` when cluster details are unavailable.
    pub fn from_run(run: &RunAggregate) -> Result<Self, CliError> {
        let spec = run
            .cluster
            .as_ref()
            .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster"))?;
        Self::from_spec(spec)
    }

    /// Build runtime access from a persisted cluster spec.
    ///
    /// # Errors
    /// Returns `CliError` when required runtime details are missing.
    pub fn from_spec(spec: &ClusterSpec) -> Result<Self, CliError> {
        match spec.platform {
            Platform::Kubernetes => Ok(Self::Kubernetes(KubernetesRuntime::from_spec(spec))),
            Platform::Universal => Ok(Self::Universal(UniversalRuntime::from_spec(spec))),
        }
    }

    #[must_use]
    pub fn platform(&self) -> Platform {
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
        explicit: Option<&str>,
        cluster: Option<&str>,
    ) -> Result<PathBuf, CliError> {
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
    pub fn control_plane_access(&self) -> Result<&ControlPlaneAccess, CliError> {
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
    pub fn xds_access(&self) -> Result<&XdsAccess, CliError> {
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
    pub fn docker_network(&self) -> Result<&str, CliError> {
        match self {
            Self::Universal(runtime) => runtime.docker_network(),
            Self::Kubernetes(_) => {
                Err(CliErrorKind::missing_run_context_value("docker_network").into())
            }
        }
    }

    /// Resolve a tracked member name to the actual container name.
    #[must_use]
    pub fn resolve_container_name(&self, requested: &str) -> String {
        match self {
            Self::Universal(runtime) => runtime.resolve_container_name(requested),
            Self::Kubernetes(_) => requested.to_string(),
        }
    }

    /// Resolve the image used for ad-hoc universal service containers.
    ///
    /// # Errors
    /// Returns `CliError` when the runtime is not universal or image derivation fails.
    pub fn service_image(&self, explicit: Option<&str>) -> Result<String, CliError> {
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
pub fn profile_platform(profile: &str) -> Platform {
    if profile == "universal" || profile.starts_with("universal-") {
        return Platform::Universal;
    }
    Platform::Kubernetes
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::{ClusterMember, HelmSetting};

    fn universal_spec() -> ClusterSpec {
        let mut spec = ClusterSpec::from_mode_with_platform(
            "global-zone-up",
            &["g".into(), "z".into(), "zone-1".into()],
            "/repo",
            vec![HelmSetting {
                key: "a".into(),
                value: "b".into(),
            }],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        spec.admin_token = Some("admin-token".into());
        spec.members[0].container_ip = Some("172.57.0.2".into());
        spec
    }

    #[test]
    fn kubernetes_runtime_uses_primary_kubeconfig_by_default() {
        let spec =
            ClusterSpec::from_mode("single-up", &["cp".into()], "/repo", vec![], vec![]).unwrap();
        let runtime = ClusterRuntime::from_spec(&spec).unwrap();
        let kubeconfig = runtime.resolve_kubeconfig(None, None).unwrap();
        assert_eq!(kubeconfig, PathBuf::from(spec.primary_kubeconfig()));
    }

    #[test]
    fn kubernetes_runtime_resolves_named_cluster() {
        let spec = ClusterSpec {
            mode: spec_mode(),
            platform: Platform::Kubernetes,
            members: vec![
                ClusterMember::named("g", "global", Some("/tmp/g"), None),
                ClusterMember::named("z", "zone", Some("/tmp/z"), Some("zone-1")),
            ],
            mode_args: vec!["g".into(), "z".into(), "zone-1".into()],
            helm_settings: vec![],
            restart_namespaces: vec![],
            repo_root: "/repo".into(),
            docker_network: None,
            store_type: None,
            cp_image: None,
            admin_token: None,
        };
        let runtime = ClusterRuntime::from_spec(&spec).unwrap();
        let kubeconfig = runtime.resolve_kubeconfig(None, Some("z")).unwrap();
        assert_eq!(kubeconfig, PathBuf::from("/tmp/z"));
    }

    #[test]
    fn universal_runtime_exposes_control_plane_access() {
        let runtime = ClusterRuntime::from_spec(&universal_spec()).unwrap();
        let access = runtime.control_plane_access().unwrap();
        assert_eq!(access.addr, "http://172.57.0.2:5681");
        assert_eq!(access.admin_token.as_deref(), Some("admin-token"));
    }

    #[test]
    fn universal_runtime_resolves_compose_member_container_name() {
        let runtime = ClusterRuntime::from_spec(&universal_spec()).unwrap();
        assert_eq!(runtime.resolve_container_name("g"), "harness-g-g-1");
        assert_eq!(runtime.resolve_container_name("demo-svc"), "demo-svc");
    }

    #[test]
    fn universal_runtime_exposes_xds_access() {
        let runtime = ClusterRuntime::from_spec(&universal_spec()).unwrap();
        let access = runtime.xds_access().unwrap();
        assert_eq!(access.ip, "172.57.0.2");
        assert_eq!(access.port, 5678);
    }

    #[test]
    fn universal_runtime_derives_service_image() {
        let mut spec = universal_spec();
        spec.cp_image = Some("docker.io/kumahq/kuma-cp:2.12.0".into());
        let runtime = ClusterRuntime::from_spec(&spec).unwrap();
        assert_eq!(
            runtime.service_image(None).unwrap(),
            "docker.io/kumahq/kuma-universal:2.12.0"
        );
    }

    #[test]
    fn profile_platform_detects_universal_variants() {
        assert_eq!(profile_platform("universal"), Platform::Universal);
        assert_eq!(profile_platform("universal-global"), Platform::Universal);
        assert_eq!(profile_platform("single-zone"), Platform::Kubernetes);
    }

    fn spec_mode() -> crate::cluster::ClusterMode {
        crate::cluster::ClusterMode::GlobalZoneUp
    }
}
