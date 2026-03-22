use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::thread;
use std::thread::ScopedJoinHandle;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::{StdProcessExecutor, kubernetes_runtime_from_env};
use crate::kernel::topology::{ClusterMode, ClusterSpec};

use super::address::resolve_kds_address;
use super::deploy::{cluster_stop, start_and_deploy};

pub(super) fn dispatch_k8s_mode(
    mode: ClusterMode,
    root: &Path,
    env: &HashMap<String, String>,
    args: &[String],
) -> Result<(), CliError> {
    match mode {
        ClusterMode::SingleUp => single_up(root, env, args),
        ClusterMode::SingleDown => single_down(root, env, args),
        ClusterMode::GlobalZoneUp => global_zone_up(root, env, args),
        ClusterMode::GlobalZoneDown => global_zone_down(root, env, args),
        ClusterMode::GlobalTwoZonesUp => global_two_zones_up(root, env, args),
        ClusterMode::GlobalTwoZonesDown => global_two_zones_down(root, env, args),
    }
}

pub(super) fn restart_cluster_namespaces(spec: &ClusterSpec) -> Result<(), CliError> {
    let kubernetes = kubernetes_runtime_from_env(Arc::new(StdProcessExecutor))?;
    for member in &spec.members {
        if member.kubeconfig.is_empty() {
            continue;
        }
        let kubeconfig = Path::new(&member.kubeconfig);
        kubernetes.rollout_restart(Some(kubeconfig), &spec.restart_namespaces)?;
    }
    Ok(())
}

fn single_up(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    if names.is_empty() {
        return Err(CliErrorKind::usage_error("single-up requires names: <cluster>").into());
    }
    start_and_deploy(root, base_env, &names[0], "zone", &[])
}

fn single_down(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    if names.is_empty() {
        return Err(CliErrorKind::usage_error("single-down requires names: <cluster>").into());
    }
    cluster_stop(root, base_env, &names[0])
}

fn global_zone_up(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    if names.len() < 3 {
        return Err(CliErrorKind::usage_error(
            "global-zone-up requires names: <global> <zone-cluster> <zone-label>",
        )
        .into());
    }
    let global_settings: Vec<String> = vec![
        "controlPlane.mode=global".into(),
        "controlPlane.globalZoneSyncService.type=NodePort".into(),
    ];
    start_and_deploy(root, base_env, &names[0], "global", &global_settings)?;
    let kds_address = resolve_kds_address(&names[0])?;
    let zone_settings = vec![
        "controlPlane.mode=zone".into(),
        format!("controlPlane.zone={}", names[2]),
        format!("controlPlane.kdsGlobalAddress={kds_address}"),
        "controlPlane.tls.kdsZoneClient.skipVerify=true".into(),
    ];
    start_and_deploy(root, base_env, &names[1], "zone", &zone_settings)
}

fn global_zone_down(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    if names.len() < 2 {
        return Err(CliErrorKind::usage_error(
            "global-zone-down requires names: <global> <zone-cluster>",
        )
        .into());
    }
    cluster_stop(root, base_env, &names[1])?;
    cluster_stop(root, base_env, &names[0])
}

fn global_two_zones_up(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    if names.len() < 5 {
        return Err(CliErrorKind::usage_error(
            "global-two-zones-up requires names: <global> <zone1-cluster> <zone2-cluster> <zone1-label> <zone2-label>",
        )
        .into());
    }
    let global_settings: Vec<String> = vec![
        "controlPlane.mode=global".into(),
        "controlPlane.globalZoneSyncService.type=NodePort".into(),
    ];
    start_and_deploy(root, base_env, &names[0], "global", &global_settings)?;
    let kds_address = resolve_kds_address(&names[0])?;
    let zone1_settings = zone_settings(&names[3], &kds_address);
    let zone2_settings = zone_settings(&names[4], &kds_address);

    thread::scope(|scope| {
        let t_zone1 = scope.spawn(move || deploy_zone(root, base_env, &names[1], &zone1_settings));
        let t_zone2 = scope.spawn(move || deploy_zone(root, base_env, &names[2], &zone2_settings));
        join_zone_deploy(t_zone1, "zone1")?;
        join_zone_deploy(t_zone2, "zone2")?;
        Ok(())
    })
}

fn global_two_zones_down(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    if names.len() < 3 {
        return Err(CliErrorKind::usage_error(
            "global-two-zones-down requires names: <global> <zone1-cluster> <zone2-cluster>",
        )
        .into());
    }
    cluster_stop(root, base_env, &names[2])?;
    cluster_stop(root, base_env, &names[1])?;
    cluster_stop(root, base_env, &names[0])
}

fn zone_settings(zone_label: &str, kds_address: &str) -> Vec<String> {
    vec![
        "controlPlane.mode=zone".into(),
        format!("controlPlane.zone={zone_label}"),
        format!("controlPlane.kdsGlobalAddress={kds_address}"),
        "controlPlane.tls.kdsZoneClient.skipVerify=true".into(),
    ]
}

fn deploy_zone(
    root: &Path,
    base_env: &HashMap<String, String>,
    cluster_name: &str,
    settings: &[String],
) -> Result<(), CliError> {
    start_and_deploy(root, base_env, cluster_name, "zone", settings)
}

fn join_zone_deploy(
    handle: ScopedJoinHandle<'_, Result<(), CliError>>,
    zone_id: &str,
) -> Result<(), CliError> {
    handle
        .join()
        .map_err(|_| CliErrorKind::cluster_error(format!("{zone_id} deployment thread panicked")))?
}
