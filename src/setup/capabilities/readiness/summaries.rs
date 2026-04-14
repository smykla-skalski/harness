use std::collections::{BTreeMap, BTreeSet};

use crate::kernel::topology::{ClusterProvider, Platform};
use crate::setup::capabilities::model::{
    Feature, PlatformReadiness, ProfileReadiness, ReadinessStatus, ReadinessSummary, TopologyMode,
};

pub(super) struct CapabilitySummaries {
    pub(super) create: ReadinessSummary,
    pub(super) project: ReadinessSummary,
    pub(super) bootstrap: ReadinessSummary,
    pub(super) repo: ReadinessSummary,
    pub(super) k3d: ReadinessSummary,
    pub(super) remote: ReadinessSummary,
    pub(super) kubernetes: ReadinessSummary,
    pub(super) universal: ReadinessSummary,
    pub(super) either_platform: ReadinessSummary,
}

const CREATE_REQUIREMENTS: &[&str] = &[
    "data_root_writable",
    "project_dir_exists",
    "suite_plugin_present",
];
const PROJECT_REQUIREMENTS: &[&str] = &[
    "project_dir_exists",
    "suite_plugin_present",
    "wrapper_install_target_available",
];
const BOOTSTRAP_REQUIREMENTS: &[&str] = &[
    "project_dir_exists",
    "suite_plugin_present",
    "wrapper_install_target_available",
];
const REPO_REQUIREMENTS: &[&str] = &[
    "repo_root_resolved",
    "repo_root_exists",
    "repo_is_kuma_checkout",
];
const K3D_REQUIREMENTS: &[&str] = &[
    "docker_binary_present",
    "docker_running",
    "make_binary_present",
    "k3d_binary_present",
    "kubernetes_runtime_ready",
    "helm_binary_present",
    "repo_root_resolved",
    "repo_root_exists",
    "repo_is_kuma_checkout",
    "repo_make_contract_present",
];
const REMOTE_REQUIREMENTS: &[&str] = &[
    "docker_binary_present",
    "docker_running",
    "make_binary_present",
    "kubernetes_runtime_ready",
    "helm_binary_present",
    "repo_root_resolved",
    "repo_root_exists",
    "repo_is_kuma_checkout",
    "repo_make_contract_present",
    "repo_remote_publish_contract_present",
];
const UNIVERSAL_REQUIREMENTS: &[&str] = &[
    "docker_running",
    "docker_compose_available",
    "repo_root_resolved",
    "repo_root_exists",
    "repo_is_kuma_checkout",
];

pub(super) fn build_summaries(statuses: &BTreeMap<&str, ReadinessStatus>) -> CapabilitySummaries {
    let create = summary_from_codes(statuses, CREATE_REQUIREMENTS);
    let project = summary_from_codes(statuses, PROJECT_REQUIREMENTS);
    let bootstrap = summary_from_codes(statuses, BOOTSTRAP_REQUIREMENTS);
    let repo = summary_from_codes(statuses, REPO_REQUIREMENTS);
    let k3d = summary_from_codes(statuses, K3D_REQUIREMENTS);
    let remote = summary_from_codes(statuses, REMOTE_REQUIREMENTS);
    let kubernetes = any_of(&[&k3d, &remote]);
    let universal = summary_from_codes(statuses, UNIVERSAL_REQUIREMENTS);
    let either_platform = any_of(&[&kubernetes, &universal]);

    CapabilitySummaries {
        create,
        project,
        bootstrap,
        repo,
        k3d,
        remote,
        kubernetes,
        universal,
        either_platform,
    }
}

pub(super) fn build_platform_readiness(
    summaries: &CapabilitySummaries,
) -> BTreeMap<String, PlatformReadiness> {
    BTreeMap::from([
        (
            Platform::Kubernetes.as_str().to_string(),
            PlatformReadiness {
                ready: summaries.kubernetes.ready,
                blocking_checks: summaries.kubernetes.blocking_checks.clone(),
            },
        ),
        (
            Platform::Universal.as_str().to_string(),
            PlatformReadiness {
                ready: summaries.universal.ready,
                blocking_checks: summaries.universal.blocking_checks.clone(),
            },
        ),
    ])
}

pub(super) fn build_provider_readiness(
    summaries: &CapabilitySummaries,
) -> BTreeMap<String, ReadinessSummary> {
    BTreeMap::from([
        (
            ClusterProvider::K3d.as_str().to_string(),
            summaries.k3d.clone(),
        ),
        (
            ClusterProvider::Remote.as_str().to_string(),
            summaries.remote.clone(),
        ),
        (
            ClusterProvider::Compose.as_str().to_string(),
            summaries.universal.clone(),
        ),
    ])
}

pub(super) fn build_profile_readiness(summaries: &CapabilitySummaries) -> Vec<ProfileReadiness> {
    vec![
        profile_readiness(
            "single-zone",
            Platform::Kubernetes,
            ClusterProvider::K3d,
            TopologyMode::SingleZone,
            &summaries.k3d,
        ),
        profile_readiness(
            "multi-zone",
            Platform::Kubernetes,
            ClusterProvider::K3d,
            TopologyMode::MultiZone,
            &summaries.k3d,
        ),
        profile_readiness(
            "single-zone",
            Platform::Kubernetes,
            ClusterProvider::Remote,
            TopologyMode::SingleZone,
            &summaries.remote,
        ),
        profile_readiness(
            "multi-zone",
            Platform::Kubernetes,
            ClusterProvider::Remote,
            TopologyMode::MultiZone,
            &summaries.remote,
        ),
        profile_readiness(
            "single-zone-universal",
            Platform::Universal,
            ClusterProvider::Compose,
            TopologyMode::SingleZone,
            &summaries.universal,
        ),
        profile_readiness(
            "multi-zone-universal",
            Platform::Universal,
            ClusterProvider::Compose,
            TopologyMode::MultiZone,
            &summaries.universal,
        ),
    ]
}

fn profile_readiness(
    name: &str,
    platform: Platform,
    provider: ClusterProvider,
    topology: TopologyMode,
    summary: &ReadinessSummary,
) -> ProfileReadiness {
    ProfileReadiness {
        name: name.into(),
        platform,
        provider,
        topology,
        ready: summary.ready,
        blocking_checks: summary.blocking_checks.clone(),
    }
}

fn summary_from_codes(
    statuses: &BTreeMap<&str, ReadinessStatus>,
    codes: &[&str],
) -> ReadinessSummary {
    let ready = codes
        .iter()
        .all(|code| statuses.get(code).copied() == Some(ReadinessStatus::Pass));
    let blocking_checks = codes
        .iter()
        .filter(|code| statuses.get(**code).copied() == Some(ReadinessStatus::Fail))
        .map(|code| (*code).to_string())
        .collect();
    ReadinessSummary {
        ready,
        blocking_checks,
    }
}

fn any_of(summaries: &[&ReadinessSummary]) -> ReadinessSummary {
    if summaries.iter().any(|summary| summary.ready) {
        return ReadinessSummary {
            ready: true,
            blocking_checks: vec![],
        };
    }

    let blocking_checks = summaries
        .iter()
        .flat_map(|summary| summary.blocking_checks.iter().cloned())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    ReadinessSummary {
        ready: false,
        blocking_checks,
    }
}

pub(super) struct FeatureReadinessInputs<'a> {
    pub(super) project: &'a ReadinessSummary,
    pub(super) bootstrap: &'a ReadinessSummary,
    pub(super) repo: &'a ReadinessSummary,
    pub(super) kubernetes: &'a ReadinessSummary,
    pub(super) universal: &'a ReadinessSummary,
    pub(super) either_platform: &'a ReadinessSummary,
}

pub(super) fn feature_summary(
    feature: Feature,
    inputs: &FeatureReadinessInputs<'_>,
) -> ReadinessSummary {
    match feature {
        Feature::Bootstrap => inputs.bootstrap.clone(),
        Feature::HookSystem
        | Feature::Observation
        | Feature::PreCompactHandoff
        | Feature::SessionLifecycle => inputs.project.clone(),
        Feature::GatewayApi
        | Feature::HelmSettings
        | Feature::MultiZoneKdsAutoConfig
        | Feature::NamespaceRestart => inputs.kubernetes.clone(),
        Feature::DataplaneTokens | Feature::ServiceContainers | Feature::TransparentProxy => {
            inputs.universal.clone()
        }
        Feature::Kumactl => inputs.repo.clone(),
        Feature::ApiAccess
        | Feature::ClusterCheck
        | Feature::ClusterManagement
        | Feature::ContainerLogs
        | Feature::EnvoyAdmin
        | Feature::ManifestApply
        | Feature::ManifestValidate
        | Feature::RunLifecycle
        | Feature::StateCapture
        | Feature::StatusReport
        | Feature::TrackedRecording => inputs.either_platform.clone(),
        Feature::BugFoundGate
        | Feature::GlobalDelay
        | Feature::IdempotentGroupReporting
        | Feature::JsonDiff
        | Feature::ProgressHeartbeat
        | Feature::TaskManagement => ReadinessSummary {
            ready: true,
            blocking_checks: vec![],
        },
    }
}
