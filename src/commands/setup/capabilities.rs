use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::cluster::Platform;
use crate::errors::{CliError, CliErrorKind};

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
/// derived `Ord` produces the same key order as the previous `BTreeMap`-backed
/// `json!()` output.
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
    fn new(description: &str) -> Self {
        Self {
            available: true,
            command: None,
            commands: None,
            description: description.into(),
            platforms: None,
        }
    }

    fn command(mut self, value: &str) -> Self {
        self.command = Some(value.into());
        self
    }

    fn commands(mut self, values: &[&str]) -> Self {
        self.commands = Some(values.iter().map(|&s| s.into()).collect());
        self
    }

    fn platforms(mut self, values: &[Platform]) -> Self {
        self.platforms = Some(values.to_vec());
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoringInfo {
    pub available: bool,
    pub commands: Vec<String>,
    pub description: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CapabilitiesReport {
    pub authoring: AuthoringInfo,
    pub cluster_topologies: Vec<ClusterTopology>,
    pub features: BTreeMap<Feature, FeatureInfo>,
    pub platforms: Vec<PlatformInfo>,
}

fn platforms() -> Vec<PlatformInfo> {
    vec![
        PlatformInfo {
            name: Platform::Kubernetes,
            aliases: vec!["k8s".into()],
            description: "k3d-based local Kubernetes clusters with Helm-deployed Kuma".into(),
        },
        PlatformInfo {
            name: Platform::Universal,
            aliases: vec![],
            description: "Docker-based universal mode with CP containers and dataplane tokens"
                .into(),
        },
    ]
}

fn cluster_topologies() -> Vec<ClusterTopology> {
    vec![
        ClusterTopology {
            mode: TopologyMode::SingleZone,
            profiles: vec!["single-zone".into(), "single-zone-universal".into()],
            description: "single CP with one cluster or one Docker CP container".into(),
        },
        ClusterTopology {
            mode: TopologyMode::MultiZone,
            profiles: vec!["multi-zone".into(), "multi-zone-universal".into()],
            description: "global CP with one or two zone CPs (k3d or Docker)".into(),
        },
    ]
}

fn features() -> BTreeMap<Feature, FeatureInfo> {
    let mut map = core_features();
    map.extend(extended_features());
    map.extend(operational_features());
    map
}

fn core_features() -> BTreeMap<Feature, FeatureInfo> {
    let universal = &[Platform::Universal];
    let kubernetes = &[Platform::Kubernetes];
    BTreeMap::from([
        (
            Feature::ApiAccess,
            FeatureInfo::new("send HTTP requests to CP REST API endpoints").commands(&[
                "harness api get",
                "harness api post",
                "harness api put",
                "harness api delete",
            ]),
        ),
        (
            Feature::Bootstrap,
            FeatureInfo::new("initialize a test run with cluster and session context")
                .command("harness bootstrap"),
        ),
        (
            Feature::ClusterCheck,
            FeatureInfo::new("verify cluster containers and networks are still running")
                .command("harness cluster-check"),
        ),
        (
            Feature::ClusterManagement,
            FeatureInfo::new("create and tear down local k3d or universal Docker clusters")
                .command("harness cluster"),
        ),
        (
            Feature::ContainerLogs,
            FeatureInfo::new("view logs from cluster or service containers")
                .command("harness logs"),
        ),
        (
            Feature::DataplaneTokens,
            FeatureInfo::new(
                "generate dataplane/ingress/egress tokens from CP REST API or kumactl",
            )
            .command("harness token")
            .platforms(universal),
        ),
        (
            Feature::EnvoyAdmin,
            FeatureInfo::new(
                "capture and inspect Envoy config dumps, routes, listeners, clusters, bootstrap",
            )
            .commands(&[
                "harness envoy capture",
                "harness envoy route-body",
                "harness envoy bootstrap",
            ]),
        ),
        (
            Feature::GatewayApi,
            FeatureInfo::new("install Gateway API CRDs from go.mod-pinned version")
                .command("harness gateway"),
        ),
        (
            Feature::HelmSettings,
            FeatureInfo::new("pass custom Helm values during cluster bootstrap")
                .platforms(kubernetes),
        ),
        (
            Feature::JsonDiff,
            FeatureInfo::new("key-by-key JSON diff between two payloads").command("harness diff"),
        ),
        (
            Feature::Kumactl,
            FeatureInfo::new("find or build kumactl from local repo checkout")
                .commands(&["harness kumactl find", "harness kumactl build"]),
        ),
        (
            Feature::ManifestApply,
            FeatureInfo::new("tracked manifest application with validation, copy, and logging")
                .command("harness apply"),
        ),
        (
            Feature::ManifestValidate,
            FeatureInfo::new("server-side dry-run validation before apply")
                .command("harness validate"),
        ),
    ])
}

fn extended_features() -> BTreeMap<Feature, FeatureInfo> {
    let universal = &[Platform::Universal];
    let kubernetes = &[Platform::Kubernetes];
    BTreeMap::from([
        (
            Feature::MultiZoneKdsAutoConfig,
            FeatureInfo::new(
                "automatic KDS address resolution for zone control planes in multi-zone topologies",
            ),
        ),
        (
            Feature::NamespaceRestart,
            FeatureInfo::new("restart workloads in specified namespaces after deployment changes")
                .platforms(kubernetes),
        ),
        (
            Feature::Observation,
            FeatureInfo::new(
                "session monitoring with scan, watch, cycle, verify, compare, and doctor modes",
            )
            .commands(&[
                "harness observe scan",
                "harness observe watch",
                "harness observe cycle",
                "harness observe dump",
                "harness observe context",
                "harness observe status",
                "harness observe resume",
                "harness observe verify",
                "harness observe resolve-start",
                "harness observe compare",
                "harness observe doctor",
                "harness observe mute",
                "harness observe unmute",
                "harness observe list-categories",
                "harness observe list-focus-presets",
            ]),
        ),
        (
            Feature::PreCompactHandoff,
            FeatureInfo::new("context compaction before session handoff")
                .command("harness pre-compact"),
        ),
        (
            Feature::ProgressHeartbeat,
            FeatureInfo::new("30-second heartbeat during long operations to signal liveness"),
        ),
        (
            Feature::RunLifecycle,
            FeatureInfo::new("full run lifecycle: init, preflight, execute, report, closeout")
                .commands(&[
                    "harness init",
                    "harness preflight",
                    "harness runner-state",
                    "harness report group",
                    "harness report check",
                    "harness closeout",
                ]),
        ),
        (
            Feature::ServiceContainers,
            FeatureInfo::new("manage test service Docker containers with dataplane sidecars")
                .command("harness service")
                .platforms(universal),
        ),
        (
            Feature::SessionLifecycle,
            FeatureInfo::new(
                "start and stop session boundaries for observation and state tracking",
            )
            .commands(&["harness session-start", "harness session-stop"]),
        ),
        (
            Feature::StateCapture,
            FeatureInfo::new("snapshot cluster pod state as timestamped artifacts")
                .command("harness capture"),
        ),
        (
            Feature::StatusReport,
            FeatureInfo::new("show cluster state, members, services, and dataplanes as JSON")
                .command("harness status"),
        ),
        (
            Feature::TaskManagement,
            FeatureInfo::new("background task polling and log tailing for long-running operations")
                .commands(&["harness task wait", "harness task tail"]),
        ),
        (
            Feature::TrackedRecording,
            FeatureInfo::new("record arbitrary shell commands with stdout capture and audit trail")
                .commands(&["harness record", "harness run"]),
        ),
        (
            Feature::TransparentProxy,
            FeatureInfo::new("install transparent proxy on universal service containers")
                .platforms(universal),
        ),
    ])
}

fn operational_features() -> BTreeMap<Feature, FeatureInfo> {
    BTreeMap::from([
        (
            Feature::BugFoundGate,
            FeatureInfo::new("KSR016 enforcement during Phase 4+ to gate on discovered bugs"),
        ),
        (
            Feature::GlobalDelay,
            FeatureInfo::new("--delay flag for pre-command sleep on any harness invocation"),
        ),
        (
            Feature::HookSystem,
            FeatureInfo::new(
                "12 hook types intercepting tool usage: guard-bash, guard-write, guard-question, \
                 guard-stop, verify-bash, verify-write, verify-question, audit, enrich-failure, \
                 context-agent, validate-agent",
            )
            .command("harness hook"),
        ),
        (
            Feature::IdempotentGroupReporting,
            FeatureInfo::new("report group accepts re-reports gracefully without duplication")
                .command("harness report group"),
        ),
    ])
}

fn authoring() -> AuthoringInfo {
    AuthoringInfo {
        available: true,
        commands: vec![
            "harness authoring-begin".into(),
            "harness authoring-save".into(),
            "harness authoring-show".into(),
            "harness authoring-reset".into(),
            "harness authoring-validate".into(),
            "harness approval-begin".into(),
        ],
        description: "interactive suite authoring with discovery workers and approval gates".into(),
    }
}

/// Report harness capabilities as structured JSON for skill planning.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn capabilities() -> Result<i32, CliError> {
    let caps = CapabilitiesReport {
        authoring: authoring(),
        cluster_topologies: cluster_topologies(),
        features: features(),
        platforms: platforms(),
    };
    let output = serde_json::to_string_pretty(&caps)
        .map_err(|e| CliErrorKind::io(format!("json serialize: {e}")))?;
    println!("{output}");
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capabilities_returns_zero() {
        assert_eq!(capabilities().unwrap(), 0);
    }

    #[test]
    fn output_contains_expected_sections() {
        let caps = CapabilitiesReport {
            authoring: authoring(),
            cluster_topologies: cluster_topologies(),
            features: features(),
            platforms: platforms(),
        };
        assert!(caps.authoring.available);
        assert!(!caps.cluster_topologies.is_empty());
        assert!(!caps.features.is_empty());
        assert!(!caps.platforms.is_empty());
    }

    #[test]
    fn platforms_lists_both() {
        let p = platforms();
        let names: Vec<Platform> = p.iter().map(|pi| pi.name).collect();
        assert!(names.contains(&Platform::Kubernetes));
        assert!(names.contains(&Platform::Universal));
    }

    #[test]
    fn features_include_universal_only_items() {
        let f = features();
        let tokens = f.get(&Feature::DataplaneTokens).unwrap();
        assert!(tokens.available);
        let plats = tokens.platforms.as_ref().unwrap();
        assert_eq!(plats.len(), 1);
        assert_eq!(plats[0], Platform::Universal);
    }

    #[test]
    fn json_round_trip() {
        let caps = CapabilitiesReport {
            authoring: authoring(),
            cluster_topologies: cluster_topologies(),
            features: features(),
            platforms: platforms(),
        };
        let json = serde_json::to_string(&caps).unwrap();
        let deserialized: CapabilitiesReport = serde_json::from_str(&json).unwrap();
        assert_eq!(caps, deserialized);
    }

    #[test]
    fn features_include_api_cluster_bootstrap() {
        let f = features();
        assert!(f.contains_key(&Feature::ApiAccess));
        assert!(f.contains_key(&Feature::Bootstrap));
        assert!(f.contains_key(&Feature::ClusterManagement));
    }

    #[test]
    fn feature_count_is_current() {
        let f = features();
        assert_eq!(f.len(), 30, "feature count changed - update this test");
    }

    #[test]
    fn feature_keys_are_snake_case() {
        let f = features();
        let value = serde_json::to_value(&f).unwrap();
        let map = value.as_object().unwrap();
        for key in map.keys() {
            assert!(
                key.chars().all(|c| c.is_ascii_lowercase() || c == '_'),
                "feature key {key:?} is not snake_case"
            );
        }
    }
}
