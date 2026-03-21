use std::collections::HashMap;
use std::path::Path;
use std::thread;

use tracing::info;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::exec::kubectl_rollout_restart;
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
    for member in &spec.members {
        if member.kubeconfig.is_empty() {
            continue;
        }
        let kubeconfig = Path::new(&member.kubeconfig);
        kubectl_rollout_restart(Some(kubeconfig), &spec.restart_namespaces)?;
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
    let zone1_settings = vec![
        "controlPlane.mode=zone".into(),
        format!("controlPlane.zone={}", names[3]),
        format!("controlPlane.kdsGlobalAddress={kds_address}"),
        "controlPlane.tls.kdsZoneClient.skipVerify=true".into(),
    ];
    let zone2_settings = vec![
        "controlPlane.mode=zone".into(),
        format!("controlPlane.zone={}", names[4]),
        format!("controlPlane.kdsGlobalAddress={kds_address}"),
        "controlPlane.tls.kdsZoneClient.skipVerify=true".into(),
    ];

    thread::scope(|scope| {
        let zone1_cluster = &names[1];
        let zone1_name = &names[3];
        let zone2_cluster = &names[2];
        let zone2_name = &names[4];
        let t_zone1 = scope.spawn(move || {
            info!(zone = %zone1_name, cluster = %zone1_cluster, "deploying zone");
            start_and_deploy(root, base_env, zone1_cluster, "zone", &zone1_settings)?;
            info!(zone = %zone1_name, cluster = %zone1_cluster, "zone ready");
            Ok::<(), CliError>(())
        });
        let t_zone2 = scope.spawn(move || {
            info!(zone = %zone2_name, cluster = %zone2_cluster, "deploying zone");
            start_and_deploy(root, base_env, zone2_cluster, "zone", &zone2_settings)?;
            info!(zone = %zone2_name, cluster = %zone2_cluster, "zone ready");
            Ok::<(), CliError>(())
        });
        t_zone1
            .join()
            .map_err(|_| CliErrorKind::cluster_error("zone1 deployment thread panicked"))??;
        t_zone2
            .join()
            .map_err(|_| CliErrorKind::cluster_error("zone2 deployment thread panicked"))??;
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
