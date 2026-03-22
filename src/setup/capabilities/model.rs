use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::kernel::topology::{ClusterProvider, Platform};

/// Cluster topology mode (single-zone vs multi-zone).
///
/// Separate from `ClusterMode` which covers lifecycle operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
#[non_exhaustive]
pub enum TopologyMode {
    SingleZone,
    MultiZone,
}

/// Feature identifier, serialized as `snake_case`.
///
/// Variants are declared in alphabetical order by `snake_case` name so that the
/// derived `Ord` produces the same key order as the previous `BTreeMap` output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum Feature {
    ApiAccess,
    Bootstrap,
    BugFoundGate,
    ClusterCheck,
    ClusterManagement,
    ContainerLogs,
    DataplaneTokens,
    EnvoyAdmin,
    GatewayApi,
    GlobalDelay,
    HelmSettings,
    HookSystem,
    IdempotentGroupReporting,
    JsonDiff,
    Kumactl,
    ManifestApply,
    ManifestValidate,
    MultiZoneKdsAutoConfig,
    NamespaceRestart,
    Observation,
    PreCompactHandoff,
    ProgressHeartbeat,
    RunLifecycle,
    ServiceContainers,
    SessionLifecycle,
    StateCapture,
    StatusReport,
    TaskManagement,
    TrackedRecording,
    TransparentProxy,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlatformInfo {
    pub aliases: Vec<String>,
    pub description: String,
    pub name: Platform,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderInfo {
    pub aliases: Vec<String>,
    pub description: String,
    pub name: ClusterProvider,
    pub platform: Platform,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClusterTopology {
    pub description: String,
    pub mode: TopologyMode,
    pub profiles: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeatureInfo {
    pub available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commands: Option<Vec<String>>,
    pub description: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platforms: Option<Vec<Platform>>,
}

impl FeatureInfo {
    pub(super) fn new(description: &str) -> Self {
        Self {
            available: true,
            command: None,
            commands: None,
            description: description.into(),
            platforms: None,
        }
    }

    pub(super) fn command(mut self, value: &str) -> Self {
        self.command = Some(value.into());
        self
    }

    pub(super) fn commands(mut self, values: &[&str]) -> Self {
        self.commands = Some(values.iter().map(|&s| s.into()).collect());
        self
    }

    pub(super) fn platforms(mut self, values: &[Platform]) -> Self {
        self.platforms = Some(values.to_vec());
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateInfo {
    pub available: bool,
    pub commands: Vec<String>,
    pub description: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReadinessCheckScope {
    Machine,
    Project,
    Repo,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReadinessStatus {
    Pass,
    Fail,
    Skipped,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadinessScope {
    pub cwd: String,
    pub project_dir: String,
    pub repo_root: Option<String>,
    pub explicit_project_dir: bool,
    pub explicit_repo_root: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadinessCheck {
    pub code: String,
    pub scope: ReadinessCheckScope,
    pub status: ReadinessStatus,
    pub summary: String,
    pub path: Option<String>,
    pub hint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadinessSummary {
    pub ready: bool,
    pub blocking_checks: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlatformReadiness {
    pub ready: bool,
    pub blocking_checks: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProfileReadiness {
    pub name: String,
    pub platform: Platform,
    pub provider: ClusterProvider,
    pub topology: TopologyMode,
    pub ready: bool,
    pub blocking_checks: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReadinessReport {
    pub scope: ReadinessScope,
    pub checks: Vec<ReadinessCheck>,
    pub create: ReadinessSummary,
    pub platforms: BTreeMap<String, PlatformReadiness>,
    pub providers: BTreeMap<String, ReadinessSummary>,
    pub features: BTreeMap<Feature, ReadinessSummary>,
    pub profiles: Vec<ProfileReadiness>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilitiesReport {
    pub create: CreateInfo,
    pub cluster_topologies: Vec<ClusterTopology>,
    pub features: BTreeMap<Feature, FeatureInfo>,
    pub platforms: Vec<PlatformInfo>,
    pub providers: Vec<ProviderInfo>,
    pub readiness: ReadinessReport,
}
