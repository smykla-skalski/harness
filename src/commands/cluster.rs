use std::collections::HashMap;
use std::env;
use std::path::Path;

use crate::cluster::{ClusterSpec, HelmSetting};
use crate::core_defs::{resolve_build_info, utc_now};
use crate::errors::CliError;
use crate::exec::{cluster_exists, run_command};

fn make_target(root: &Path, target: &str, env: &HashMap<String, String>) -> Result<(), CliError> {
    run_command(&["make", target], Some(root), Some(env), &[0])?;
    Ok(())
}

/// Manage disposable local k3d clusters.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(
    mode: &str,
    cluster_name: &str,
    extra_cluster_names: &[String],
    repo_root: Option<&str>,
    _run_dir: Option<&str>,
    helm_setting: &[String],
    restart_namespace: &[String],
) -> Result<i32, CliError> {
    let mut all_names = vec![cluster_name.to_string()];
    all_names.extend(extra_cluster_names.iter().cloned());

    let root = super::resolve_repo_root(repo_root);
    let build_info = resolve_build_info(&root)?;
    let mut base_env = build_info.env();

    let helm_settings: Vec<HelmSetting> = helm_setting
        .iter()
        .filter_map(|s| HelmSetting::from_cli_arg(s).ok())
        .collect();

    // NOTE: The spec is built here for validation (rejects unknown modes and
    // wrong argument counts) but the actual cluster operations below still call
    // standalone make-target helpers that don't consume the spec.  A future
    // refactor should drive the operations from `spec.members` directly.
    let _spec = ClusterSpec::from_mode(
        mode,
        &all_names,
        &root.to_string_lossy(),
        helm_settings.clone(),
        restart_namespace.to_vec(),
    )
    .map_err(|e| CliError {
        code: "CLUSTER".to_string(),
        message: e,
        exit_code: 1,
        hint: None,
        details: None,
    })?;

    if !helm_settings.is_empty() {
        let settings_str: Vec<String> = helm_settings.iter().map(HelmSetting::to_cli_arg).collect();
        base_env.insert(
            "K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS".to_string(),
            settings_str.join(" "),
        );
    }

    eprintln!(
        "{} cluster: starting {mode} for {}",
        utc_now(),
        all_names.join(" ")
    );

    match mode {
        "single-up" => single_up(&root, &base_env, &all_names)?,
        "single-down" => single_down(&root, &base_env, &all_names)?,
        "global-zone-up" => global_zone_up(&root, &base_env, &all_names)?,
        "global-zone-down" => global_zone_down(&root, &base_env, &all_names)?,
        "global-two-zones-up" => global_two_zones_up(&root, &base_env, &all_names)?,
        "global-two-zones-down" => global_two_zones_down(&root, &base_env, &all_names)?,
        _ => {
            return Err(CliError {
                code: "CLUSTER".to_string(),
                message: format!("unsupported cluster mode: {mode}"),
                exit_code: 1,
                hint: None,
                details: None,
            });
        }
    }

    println!("{mode} completed");
    Ok(0)
}

fn start_and_deploy(
    root: &Path,
    base_env: &HashMap<String, String>,
    cluster: &str,
    kuma_mode: &str,
    extra_settings: &[String],
) -> Result<(), CliError> {
    let mut env = base_env.clone();
    env.insert("KIND_CLUSTER_NAME".to_string(), cluster.to_string());
    if !cluster_exists(cluster)? {
        eprintln!("{} cluster: starting k3d cluster {cluster}", utc_now());
        make_target(root, "k3d/start", &env)?;
    }
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let kubeconfig = format!("{home}/.kube/kind-{cluster}-config");
    env.insert("KUBECONFIG".to_string(), kubeconfig);
    env.insert("K3D_HELM_DEPLOY_NO_CNI".to_string(), "true".to_string());
    env.insert("KUMA_MODE".to_string(), kuma_mode.to_string());
    if !extra_settings.is_empty() {
        let existing = env
            .get("K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS")
            .cloned()
            .unwrap_or_default();
        let mut all: Vec<String> = if existing.is_empty() {
            vec![]
        } else {
            existing.split_whitespace().map(String::from).collect()
        };
        all.extend(extra_settings.iter().cloned());
        env.insert(
            "K3D_HELM_DEPLOY_ADDITIONAL_SETTINGS".to_string(),
            all.join(" "),
        );
    }
    eprintln!(
        "{} cluster: deploying Kuma to {cluster} ({kuma_mode})",
        utc_now()
    );
    make_target(root, "k3d/deploy/helm", &env)?;
    Ok(())
}

fn stop(root: &Path, base_env: &HashMap<String, String>, cluster: &str) -> Result<(), CliError> {
    if !cluster_exists(cluster)? {
        println!("cluster {cluster} is already absent");
        return Ok(());
    }
    let mut env = base_env.clone();
    env.insert("KIND_CLUSTER_NAME".to_string(), cluster.to_string());
    make_target(root, "k3d/stop", &env)?;
    Ok(())
}

fn single_up(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    start_and_deploy(root, base_env, &names[0], "zone", &[])
}

fn single_down(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    stop(root, base_env, &names[0])
}

fn global_zone_up(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    let global_settings: Vec<String> = vec![
        "controlPlane.mode=global".into(),
        "controlPlane.globalZoneSyncService.type=NodePort".into(),
    ];
    start_and_deploy(root, base_env, &names[0], "global", &global_settings)?;
    let zone_settings = vec![
        "controlPlane.mode=zone".into(),
        format!("controlPlane.zone={}", names[2]),
        "controlPlane.tls.kdsZoneClient.skipVerify=true".into(),
    ];
    start_and_deploy(root, base_env, &names[1], "zone", &zone_settings)
}

fn global_zone_down(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    stop(root, base_env, &names[1])?;
    stop(root, base_env, &names[0])
}

fn global_two_zones_up(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    let global_settings: Vec<String> = vec![
        "controlPlane.mode=global".into(),
        "controlPlane.globalZoneSyncService.type=NodePort".into(),
    ];
    start_and_deploy(root, base_env, &names[0], "global", &global_settings)?;
    for (zone_cluster, zone_name) in [(&names[1], &names[3]), (&names[2], &names[4])] {
        let zone_settings = vec![
            "controlPlane.mode=zone".into(),
            format!("controlPlane.zone={zone_name}"),
            "controlPlane.tls.kdsZoneClient.skipVerify=true".into(),
        ];
        start_and_deploy(root, base_env, zone_cluster, "zone", &zone_settings)?;
    }
    Ok(())
}

fn global_two_zones_down(
    root: &Path,
    base_env: &HashMap<String, String>,
    names: &[String],
) -> Result<(), CliError> {
    stop(root, base_env, &names[2])?;
    stop(root, base_env, &names[1])?;
    stop(root, base_env, &names[0])
}
