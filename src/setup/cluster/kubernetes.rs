use std::collections::HashMap;
use std::env;
use std::path::Path;
use std::thread;

use tracing::info;

use crate::platform::cluster::{ClusterMode, ClusterSpec, HelmSetting};
use crate::app::command_context::resolve_repo_root;
use crate::core_defs::resolve_build_info;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::infra::exec;
use crate::infra::exec::{cluster_exists, docker, kubectl};

use super::{ClusterArgs, make_target, make_target_live, persist_cluster_spec};

/// Helm settings that fix init container CPU throttling on k3d clusters.
///
/// Without these, `kuma-init` containers get CPU-throttled by k3d's default
/// cgroup limits, causing pods to sit at `Init:0/1` for 2-4 minutes. Setting
/// the CPU limit to `0` removes the limit entirely; a small request is kept
/// so the scheduler has a baseline.
const INIT_CONTAINER_THROTTLE_FIX: &[&str] = &[
    "runtime.kubernetes.injector.initContainer.resources.limits.cpu=0",
    "runtime.kubernetes.injector.initContainer.resources.requests.cpu=10m",
];

/// Resolve the KDS address for a global CP running in a k3d cluster.
///
/// Discovers the k3d server node IP via `docker inspect` and the
/// `kuma-global-zone-sync` service `NodePort` via `kubectl`, then
/// returns `grpcs://<node-ip>:<node-port>`.
fn resolve_kds_address(global_cluster: &str) -> Result<String, CliError> {
    let node_container = format!("k3d-{global_cluster}-server-0");
    let format_string = "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}";
    let ip_result = docker(&["inspect", "-f", format_string, &node_container], &[0])?;
    let node_ip = ip_result.stdout.trim().to_string();
    if node_ip.is_empty() {
        return Err(CliErrorKind::cluster_error(cow!(
            "could not resolve IP for k3d node {node_container}"
        ))
        .into());
    }

    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let kubeconfig = format!("{home}/.kube/kind-{global_cluster}-config");
    let kubeconfig_path = Path::new(&kubeconfig);
    let port_result = kubectl(
        Some(kubeconfig_path),
        &[
            "get",
            "svc",
            "-n",
            "kuma-system",
            "kuma-global-zone-sync",
            "-o",
            "jsonpath={.spec.ports[?(@.name==\"global-zone-sync\")].nodePort}",
        ],
        &[0],
    )?;
    let node_port = port_result.stdout.trim().to_string();
    if node_port.is_empty() {
        return Err(CliErrorKind::cluster_error(cow!(
            "could not resolve KDS NodePort for global cluster {global_cluster}"
        ))
        .into());
    }

    let address = format!("grpcs://{node_ip}:{node_port}");
    info!(%address, "resolved global KDS address");
    Ok(address)
}

pub(super) fn cluster_k8s(args: &ClusterArgs) -> Result<i32, CliError> {
    let mode = &args.mode;
    let mut all_names = vec![args.cluster_name.clone()];
    all_names.extend(args.extra_cluster_names.iter().cloned());

    let root = resolve_repo_root(args.repo_root.as_deref());
    let build_info = resolve_build_info(&root)?;
    let mut base_env = build_info.env();

    if args.no_build {
        base_env.insert("HARNESS_BUILD_IMAGES".into(), "0".into());
    }

    if args.no_load {
        base_env.insert("HARNESS_LOAD_IMAGES".into(), "0".into());
    }

    let mut bad_settings = Vec::new();
    let helm_settings: Vec<HelmSetting> = args
        .helm_setting
        .iter()
        .filter_map(|s| match HelmSetting::from_cli_arg(s) {
            Ok(h) => Some(h),
            Err(e) => {
                bad_settings.push(e);
                None
            }
        })
        .collect();

    if !bad_settings.is_empty() {
        return Err(CliErrorKind::usage_error(bad_settings.join("; ")).into());
    }

    let spec = ClusterSpec::from_mode(
        mode,
        &all_names,
        &root.to_string_lossy(),
        helm_settings.clone(),
        args.restart_namespace.clone(),
    )
    .map_err(|e| CliError::from(CliErrorKind::cluster_error(e)))?;

    let validated_args = &spec.mode_args;

    if !helm_settings.is_empty() {
        let settings_str: Vec<String> = helm_settings.iter().map(HelmSetting::to_cli_arg).collect();
        base_env.insert(
            "K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS".to_string(),
            settings_str.join(" "),
        );
    }

    info!(%mode, names = %validated_args.join(" "), "starting cluster");
    dispatch_k8s_mode(spec.mode, &root, &base_env, validated_args)?;

    if spec.mode.is_up() && !spec.restart_namespaces.is_empty() {
        restart_cluster_namespaces(&spec)?;
    }

    if spec.mode.is_up() {
        persist_cluster_spec(&spec)?;
    }

    println!("{mode} completed");
    Ok(0)
}

fn dispatch_k8s_mode(
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

fn restart_cluster_namespaces(spec: &ClusterSpec) -> Result<(), CliError> {
    for member in &spec.members {
        if member.kubeconfig.is_empty() {
            continue;
        }
        let kubeconfig = Path::new(&member.kubeconfig);
        exec::kubectl_rollout_restart(Some(kubeconfig), &spec.restart_namespaces)?;
    }
    Ok(())
}

fn start_and_deploy(
    root: &Path,
    base_env: &HashMap<String, String>,
    cluster_name: &str,
    kuma_mode: &str,
    extra_settings: &[String],
) -> Result<(), CliError> {
    let mut env = base_env.clone();
    env.insert("KIND_CLUSTER_NAME".to_string(), cluster_name.to_string());
    if !cluster_exists(cluster_name)? {
        info!(%cluster_name, "starting k3d cluster");
        make_target_live(root, "k3d/start", &env)?;
        info!(%cluster_name, "k3d cluster ready");
    }
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let kubeconfig = format!("{home}/.kube/kind-{cluster_name}-config");
    env.insert("KUBECONFIG".to_string(), kubeconfig);
    env.insert("K3D_HELM_DEPLOY_NO_CNI".to_string(), "true".to_string());
    env.insert("KUMA_MODE".to_string(), kuma_mode.to_string());

    // Merge existing settings, init container throttle fix, and caller extras.
    let existing = env
        .get("K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS")
        .cloned()
        .unwrap_or_default();
    let mut all: Vec<String> = if existing.is_empty() {
        vec![]
    } else {
        existing.split_whitespace().map(String::from).collect()
    };
    all.extend(INIT_CONTAINER_THROTTLE_FIX.iter().map(|s| (*s).to_string()));
    all.extend(extra_settings.iter().cloned());
    env.insert(
        "K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS".to_string(),
        all.join(" "),
    );

    info!(%cluster_name, %kuma_mode, "deploying Kuma");
    make_target_live(root, "k3d/deploy/helm", &env)?;
    info!(%cluster_name, "Kuma deployed");
    Ok(())
}

fn cluster_stop(
    root: &Path,
    base_env: &HashMap<String, String>,
    cluster_name: &str,
) -> Result<(), CliError> {
    if !cluster_exists(cluster_name)? {
        println!("cluster {cluster_name} is already absent");
        return Ok(());
    }
    let mut env = base_env.clone();
    env.insert("KIND_CLUSTER_NAME".to_string(), cluster_name.to_string());
    make_target(root, "k3d/stop", &env)?;
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
    info!("global CP deployed, starting zone clusters in parallel");

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
            info!(%zone1_name, %zone1_cluster, "deploying zone");
            start_and_deploy(root, base_env, zone1_cluster, "zone", &zone1_settings)?;
            info!(%zone1_name, %zone1_cluster, "zone ready");
            Ok::<(), CliError>(())
        });
        let t_zone2 = scope.spawn(move || {
            info!(%zone2_name, %zone2_cluster, "deploying zone");
            start_and_deploy(root, base_env, zone2_cluster, "zone", &zone2_settings)?;
            info!(%zone2_name, %zone2_cluster, "zone ready");
            Ok::<(), CliError>(())
        });
        t_zone1.join().expect("zone1 thread panicked")?;
        t_zone2.join().expect("zone2 thread panicked")?;
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
