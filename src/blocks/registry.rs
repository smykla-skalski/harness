use std::collections::BTreeSet;
use std::fmt;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::blocks::{
    BlockError, BuildSystem, ComposeOrchestrator, ContainerRuntime, HttpClient, KubernetesOperator,
    LocalClusterManager, MeshControlPlane, PackageDeployer, ProcessExecutor,
};

/// Named block requirements declared by suites and validated at preflight time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum BlockRequirement {
    Docker,
    Compose,
    Kubernetes,
    K3d,
    Helm,
    Envoy,
    Kuma,
    Build,
}

impl BlockRequirement {
    pub const ALL: &[Self] = &[
        Self::Docker,
        Self::Compose,
        Self::Kubernetes,
        Self::K3d,
        Self::Helm,
        Self::Envoy,
        Self::Kuma,
        Self::Build,
    ];

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Docker => "docker",
            Self::Compose => "compose",
            Self::Kubernetes => "kubernetes",
            Self::K3d => "k3d",
            Self::Helm => "helm",
            Self::Envoy => "envoy",
            Self::Kuma => "kuma",
            Self::Build => "build",
        }
    }

    #[must_use]
    pub fn denied_binary(self) -> Option<&'static str> {
        match self {
            Self::Docker | Self::Compose => Some("docker"),
            Self::Kubernetes => Some("kubectl"),
            Self::K3d => Some("k3d"),
            Self::Helm => Some("helm"),
            Self::Kuma => Some("kumactl"),
            Self::Envoy | Self::Build => None,
        }
    }

    /// Parse a user- or suite-supplied requirement name.
    ///
    /// Accepts both the architecture-review names and a few compatibility
    /// aliases from the current codebase.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` for unknown requirement names.
    pub fn parse(raw: &str) -> Result<Self, BlockError> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "docker" | "container-runtime" => Ok(Self::Docker),
            "compose" | "docker-compose" | "compose-orchestrator" => Ok(Self::Compose),
            "kubernetes" | "kubectl" => Ok(Self::Kubernetes),
            "k3d" | "local-cluster" | "local-cluster-manager" => Ok(Self::K3d),
            "helm" | "package-deployer" => Ok(Self::Helm),
            "envoy" | "proxy-introspector" => Ok(Self::Envoy),
            "kuma" | "mesh-control-plane" => Ok(Self::Kuma),
            "build" | "build-system" => Ok(Self::Build),
            other => Err(BlockError::message(
                "registry",
                "parse requirement",
                format!("unknown block requirement: {other}"),
            )),
        }
    }
}

impl fmt::Display for BlockRequirement {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Registry of active block implementations.
///
/// This is the architecture-review carrier object that allows commands,
/// services, and hooks to depend on a single typed registry instead of
/// constructing tool adapters ad hoc.
pub struct BlockRegistry {
    pub process: Arc<dyn ProcessExecutor>,
    pub http: Arc<dyn HttpClient>,
    pub docker: Option<Arc<dyn ContainerRuntime>>,
    pub compose: Option<Arc<dyn ComposeOrchestrator>>,
    pub kubernetes: Option<Arc<dyn KubernetesOperator>>,
    pub k3d: Option<Arc<dyn LocalClusterManager>>,
    pub helm: Option<Arc<dyn PackageDeployer>>,
    pub kuma: Option<Arc<dyn MeshControlPlane>>,
    pub build: Option<Arc<dyn BuildSystem>>,
}

impl fmt::Debug for BlockRegistry {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("BlockRegistry")
            .field("has_docker", &self.docker.is_some())
            .field("has_compose", &self.compose.is_some())
            .field("has_kubernetes", &self.kubernetes.is_some())
            .field("has_k3d", &self.k3d.is_some())
            .field("has_helm", &self.helm.is_some())
            .field("has_kuma", &self.kuma.is_some())
            .field("has_build", &self.build.is_some())
            .finish_non_exhaustive()
    }
}

impl BlockRegistry {
    #[must_use]
    pub fn new(process: Arc<dyn ProcessExecutor>, http: Arc<dyn HttpClient>) -> Self {
        Self {
            process,
            http,
            docker: None,
            compose: None,
            kubernetes: None,
            k3d: None,
            helm: None,
            kuma: None,
            build: None,
        }
    }

    #[must_use]
    pub fn with_docker(mut self, docker: Arc<dyn ContainerRuntime>) -> Self {
        self.docker = Some(docker);
        self
    }

    #[must_use]
    pub fn with_compose(mut self, compose: Arc<dyn ComposeOrchestrator>) -> Self {
        self.compose = Some(compose);
        self
    }

    #[must_use]
    pub fn with_kubernetes(mut self, kubernetes: Arc<dyn KubernetesOperator>) -> Self {
        self.kubernetes = Some(kubernetes);
        self
    }

    #[must_use]
    pub fn with_k3d(mut self, k3d: Arc<dyn LocalClusterManager>) -> Self {
        self.k3d = Some(k3d);
        self
    }

    #[must_use]
    pub fn with_helm(mut self, helm: Arc<dyn PackageDeployer>) -> Self {
        self.helm = Some(helm);
        self
    }

    #[must_use]
    pub fn with_kuma(mut self, kuma: Arc<dyn MeshControlPlane>) -> Self {
        self.kuma = Some(kuma);
        self
    }

    #[must_use]
    pub fn with_build(mut self, build: Arc<dyn BuildSystem>) -> Self {
        self.build = Some(build);
        self
    }

    #[must_use]
    pub fn supports(&self, requirement: BlockRequirement) -> bool {
        match requirement {
            BlockRequirement::Docker => self.docker.is_some(),
            BlockRequirement::Compose => self.compose.is_some(),
            BlockRequirement::Kubernetes => self.kubernetes.is_some(),
            BlockRequirement::K3d => self.k3d.is_some(),
            BlockRequirement::Helm => self.helm.is_some(),
            BlockRequirement::Kuma => self.kuma.is_some(),
            BlockRequirement::Envoy => false,
            BlockRequirement::Build => self.build.is_some(),
        }
    }

    /// Validate that all declared requirements are present.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` listing the missing blocks.
    pub fn validate_requirements(
        &self,
        requirements: &[BlockRequirement],
    ) -> Result<(), BlockError> {
        let missing = requirements
            .iter()
            .copied()
            .filter(|requirement| !self.supports(*requirement))
            .map(BlockRequirement::as_str)
            .collect::<Vec<_>>();

        if missing.is_empty() {
            return Ok(());
        }

        Err(BlockError::message(
            "registry",
            "validate requirements",
            format!("missing required blocks: {}", missing.join(", ")),
        ))
    }

    /// Parse and validate requirement names from suite/frontmatter metadata.
    ///
    /// # Errors
    ///
    /// Returns `BlockError` for unknown names or missing required blocks.
    pub fn validate_requirement_names(&self, requirements: &[String]) -> Result<(), BlockError> {
        let parsed = requirements
            .iter()
            .map(|name| BlockRequirement::parse(name))
            .collect::<Result<Vec<_>, _>>()?;
        self.validate_requirements(&parsed)
    }

    /// Aggregate binaries denied by the active blocks.
    #[must_use]
    pub fn all_denied_binaries(&self) -> BTreeSet<String> {
        let static_binaries = BlockRequirement::ALL
            .iter()
            .filter(|requirement| self.supports(**requirement))
            .filter_map(|requirement| requirement.denied_binary());

        let kuma_binaries = self
            .kuma
            .iter()
            .flat_map(|kuma| kuma.denied_binaries().iter().copied());

        let build_binaries = self
            .build
            .iter()
            .flat_map(|build| build.denied_binaries().iter().copied());

        static_binaries
            .chain(kuma_binaries)
            .chain(build_binaries)
            .map(ToString::to_string)
            .collect()
    }
}
