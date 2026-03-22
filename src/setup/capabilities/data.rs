use std::collections::BTreeMap;

use crate::kernel::topology::Platform;

use super::model::{ClusterTopology, CreateInfo, Feature, FeatureInfo, PlatformInfo, TopologyMode};

pub(super) fn platforms() -> Vec<PlatformInfo> {
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

pub(super) fn cluster_topologies() -> Vec<ClusterTopology> {
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

pub(super) fn features() -> BTreeMap<Feature, FeatureInfo> {
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
                "harness run kuma api get",
                "harness run kuma api post",
                "harness run kuma api put",
                "harness run kuma api delete",
            ]),
        ),
        (
            Feature::Bootstrap,
            FeatureInfo::new("initialize a test run with cluster and session context")
                .command("harness setup bootstrap"),
        ),
        (
            Feature::ClusterCheck,
            FeatureInfo::new("verify cluster containers and networks are still running")
                .command("harness run cluster-check"),
        ),
        (
            Feature::ClusterManagement,
            FeatureInfo::new("create and tear down local k3d or universal Docker clusters")
                .command("harness setup kuma cluster"),
        ),
        (
            Feature::ContainerLogs,
            FeatureInfo::new("view logs from cluster or service containers")
                .command("harness run logs"),
        ),
        (
            Feature::DataplaneTokens,
            FeatureInfo::new(
                "generate dataplane/ingress/egress tokens from CP REST API or kumactl",
            )
            .command("harness run kuma token")
            .platforms(universal),
        ),
        (
            Feature::EnvoyAdmin,
            FeatureInfo::new(
                "capture and inspect Envoy config dumps, routes, listeners, clusters, bootstrap",
            )
            .commands(&[
                "harness run envoy capture",
                "harness run envoy route-body",
                "harness run envoy bootstrap",
            ]),
        ),
        (
            Feature::GatewayApi,
            FeatureInfo::new("install Gateway API CRDs from go.mod-pinned version")
                .command("harness setup gateway"),
        ),
        (
            Feature::HelmSettings,
            FeatureInfo::new("pass custom Helm values during cluster bootstrap")
                .command("harness setup kuma cluster <mode> --helm-setting <key>=<value>")
                .platforms(kubernetes),
        ),
        (
            Feature::JsonDiff,
            FeatureInfo::new("key-by-key JSON diff between two payloads")
                .command("harness run diff"),
        ),
        (
            Feature::Kumactl,
            FeatureInfo::new("find or build kumactl from local repo checkout")
                .commands(&["harness run kuma cli find", "harness run kuma cli build"]),
        ),
        (
            Feature::ManifestApply,
            FeatureInfo::new("tracked manifest application with validation, copy, and logging")
                .command("harness run apply"),
        ),
        (
            Feature::ManifestValidate,
            FeatureInfo::new("server-side dry-run validation before apply")
                .command("harness run validate"),
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
                .command("harness run restart-namespace")
                .platforms(kubernetes),
        ),
        (
            Feature::Observation,
            FeatureInfo::new(
                "session monitoring through scan, watch, and dump with flag-driven observer actions",
            )
            .commands(&[
                "harness observe scan",
                "harness observe watch",
                "harness observe dump",
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
                    "harness run init",
                    "harness run preflight",
                    "harness run runner-state",
                    "harness run report group",
                    "harness run report check",
                    "harness run closeout",
                ]),
        ),
        (
            Feature::ServiceContainers,
            FeatureInfo::new("manage test service Docker containers with dataplane sidecars")
                .command("harness run kuma service")
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
                .command("harness run capture"),
        ),
        (
            Feature::StatusReport,
            FeatureInfo::new("show cluster state, members, services, and dataplanes as JSON")
                .command("harness run status"),
        ),
        (
            Feature::TaskManagement,
            FeatureInfo::new("background task polling and log tailing for long-running operations")
                .commands(&["harness run task wait", "harness run task tail"]),
        ),
        (
            Feature::TrackedRecording,
            FeatureInfo::new("record arbitrary shell commands with stdout capture and audit trail")
                .command("harness run record"),
        ),
        (
            Feature::TransparentProxy,
            FeatureInfo::new("install transparent proxy on universal service containers")
                .command("harness run kuma service up --transparent-proxy")
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
                "11 hook types intercepting tool usage: guard-bash, guard-write, guard-question, \
                 guard-stop, verify-bash, verify-write, verify-question, audit, enrich-failure, \
                 context-agent, validate-agent",
            )
            .command("harness hook"),
        ),
        (
            Feature::IdempotentGroupReporting,
            FeatureInfo::new("report group accepts re-reports gracefully without duplication")
                .command("harness run report group"),
        ),
    ])
}

pub(super) fn create() -> CreateInfo {
    CreateInfo {
        available: true,
        commands: vec![
            "harness create begin".into(),
            "harness create save".into(),
            "harness create show".into(),
            "harness create reset".into(),
            "harness create validate".into(),
            "harness create approval-begin".into(),
        ],
        description: "interactive suite create with discovery workers and approval gates".into(),
    }
}
