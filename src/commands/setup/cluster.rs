use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::Path;
use std::time::Duration;

use crate::cli::ClusterArgs;
use crate::cluster::{ClusterSpec, HelmSetting, Platform};
use crate::commands::resolve_repo_root;
use crate::compose;
use crate::context::CurrentRunRecord;
use crate::core_defs::{current_run_context_path, resolve_build_info, utc_now};
use crate::errors::{CliError, CliErrorKind, cow};
use crate::exec::{
    cluster_exists, compose_down_project, compose_up, docker_inspect_ip, docker_network_create,
    docker_network_rm, docker_rm, docker_run_detached, extract_admin_token, run_command,
    run_command_streaming, wait_for_http,
};

fn make_target(root: &Path, target: &str, env: &HashMap<String, String>) -> Result<(), CliError> {
    run_command(&["make", target], Some(root), Some(env), &[0])?;
    Ok(())
}

fn make_target_live(
    root: &Path,
    target: &str,
    env: &HashMap<String, String>,
) -> Result<(), CliError> {
    run_command_streaming(&["make", target], Some(root), Some(env), &[0])?;
    Ok(())
}

/// Manage disposable local clusters (k3d or universal Docker).
///
/// # Errors
/// Returns `CliError` on failure.
pub fn cluster(args: &ClusterArgs) -> Result<i32, CliError> {
    let platform: Platform = args
        .platform
        .parse()
        .map_err(|e: String| CliError::from(CliErrorKind::usage_error(e)))?;
    match platform {
        Platform::Kubernetes => cluster_k8s(
            &args.mode,
            &args.cluster_name,
            &args.extra_cluster_names,
            args.repo_root.as_deref(),
            &args.helm_setting,
            &args.restart_namespace,
        ),
        Platform::Universal => cluster_universal(
            &args.mode,
            &args.cluster_name,
            &args.extra_cluster_names,
            args.repo_root.as_deref(),
            &args.store,
            args.image.as_deref(),
        ),
    }
}

fn cluster_k8s(
    mode: &str,
    cluster_name: &str,
    extra_cluster_names: &[String],
    repo_root: Option<&str>,
    helm_setting: &[String],
    restart_namespace: &[String],
) -> Result<i32, CliError> {
    let mut all_names = vec![cluster_name.to_string()];
    all_names.extend(extra_cluster_names.iter().cloned());

    let root = resolve_repo_root(repo_root);
    let build_info = resolve_build_info(&root)?;
    let mut base_env = build_info.env();

    let mut bad_settings = Vec::new();
    let helm_settings: Vec<HelmSetting> = helm_setting
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
        restart_namespace.to_vec(),
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

    eprintln!(
        "{} cluster: starting {mode} for {}",
        utc_now(),
        validated_args.join(" ")
    );

    match mode {
        "single-up" => single_up(&root, &base_env, validated_args)?,
        "single-down" => single_down(&root, &base_env, validated_args)?,
        "global-zone-up" => global_zone_up(&root, &base_env, validated_args)?,
        "global-zone-down" => global_zone_down(&root, &base_env, validated_args)?,
        "global-two-zones-up" => global_two_zones_up(&root, &base_env, validated_args)?,
        "global-two-zones-down" => global_two_zones_down(&root, &base_env, validated_args)?,
        _ => {
            return Err(
                CliErrorKind::cluster_error(cow!("unsupported cluster mode: {mode}")).into(),
            );
        }
    }

    println!("{mode} completed");
    Ok(0)
}

fn cluster_universal(
    mode: &str,
    cluster_name: &str,
    extra_cluster_names: &[String],
    repo_root: Option<&str>,
    store: &str,
    image: Option<&str>,
) -> Result<i32, CliError> {
    let mut all_names = vec![cluster_name.to_string()];
    all_names.extend(extra_cluster_names.iter().cloned());

    let root = resolve_repo_root(repo_root);

    let mut spec = ClusterSpec::from_mode_with_platform(
        mode,
        &all_names,
        &root.to_string_lossy(),
        vec![],
        vec![],
        Platform::Universal,
    )
    .map_err(|e| CliError::from(CliErrorKind::cluster_error(e)))?;

    let network_name = spec.docker_network.as_deref().unwrap_or("harness-default");
    let is_up = spec.mode.is_up();

    // Only resolve image for up commands
    let cp_image = if is_up {
        resolve_cp_image(&root, image)?
    } else {
        String::new()
    };

    eprintln!(
        "{} cluster: starting universal {mode} for {}",
        utc_now(),
        all_names.join(" ")
    );

    match mode {
        "single-up" => {
            let result = universal_single_up(&cp_image, network_name, store, &all_names[0])?;
            spec.cp_image = Some(cp_image);
            spec.store_type = Some(store.to_string());
            spec.admin_token = Some(result.admin_token);
            spec.members[0].container_ip = Some(result.cp_ip);
        }
        "single-down" => universal_single_down(network_name, &all_names[0])?,
        "global-zone-up" => {
            let result = universal_global_zone_up(&cp_image, network_name, store, &all_names)?;
            spec.cp_image = Some(cp_image);
            spec.store_type = Some(store.to_string());
            spec.admin_token = Some(result.admin_token);
            spec.members[0].container_ip = Some(result.cp_ip);
        }
        "global-zone-down" => universal_global_zone_down(network_name, &all_names)?,
        "global-two-zones-up" => {
            let result = universal_global_two_zones_up(&cp_image, network_name, store, &all_names)?;
            spec.cp_image = Some(cp_image);
            spec.store_type = Some(store.to_string());
            spec.admin_token = Some(result.admin_token);
            spec.members[0].container_ip = Some(result.cp_ip);
        }
        "global-two-zones-down" => universal_global_two_zones_down(network_name, &all_names)?,
        _ => {
            return Err(
                CliErrorKind::cluster_error(cow!("unsupported cluster mode: {mode}")).into(),
            );
        }
    }

    if is_up {
        persist_cluster_spec(&spec)?;
    }

    println!("{mode} completed");
    Ok(0)
}

/// Result from a universal cluster up operation.
struct UniversalUpResult {
    admin_token: String,
    cp_ip: String,
}

/// Persist cluster spec to the session context and run directory if available.
fn persist_cluster_spec(spec: &ClusterSpec) -> Result<(), CliError> {
    // Update session context (current-run.json) if it exists
    let ctx_path = current_run_context_path()?;
    if let Ok(text) = fs::read_to_string(&ctx_path)
        && let Ok(mut record) = serde_json::from_str::<CurrentRunRecord>(&text)
    {
        record.cluster = Some(spec.clone());
        let json = serde_json::to_string_pretty(&record)
            .map_err(|e| CliErrorKind::serialize(cow!("cluster spec: {e}")))?;
        fs::write(&ctx_path, format!("{json}\n"))
            .map_err(|e| CliErrorKind::io(cow!("write session context: {e}")))?;

        // Also write to run dir state/cluster.json
        let run_dir = record.layout.run_dir();
        let state_dir = run_dir.join("state");
        if state_dir.is_dir() {
            let cluster_path = state_dir.join("cluster.json");
            let cluster_json = serde_json::to_string_pretty(spec)
                .map_err(|e| CliErrorKind::serialize(cow!("cluster spec: {e}")))?;
            fs::write(&cluster_path, format!("{cluster_json}\n"))
                .map_err(|e| CliErrorKind::io(cow!("write cluster spec: {e}")))?;
            eprintln!("{} cluster: spec saved to state/cluster.json", utc_now());
        }
    }

    // Always output spec JSON to stdout for scripting
    let spec_json = serde_json::to_string_pretty(&spec.to_json_dict())
        .map_err(|e| CliErrorKind::serialize(cow!("cluster spec json: {e}")))?;
    eprintln!("{spec_json}");

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
        eprintln!("{} cluster: starting k3d cluster {cluster_name}", utc_now());
        make_target_live(root, "k3d/start", &env)?;
        eprintln!("{} cluster: k3d cluster {cluster_name} ready", utc_now());
    }
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    let kubeconfig = format!("{home}/.kube/kind-{cluster_name}-config");
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
        "{} cluster: deploying Kuma to {cluster_name} ({kuma_mode})",
        utc_now()
    );
    make_target_live(root, "k3d/deploy/helm", &env)?;
    eprintln!("{} cluster: Kuma deployed to {cluster_name}", utc_now());
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
    eprintln!(
        "{} cluster: global CP deployed, starting zone clusters",
        utc_now()
    );
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

// =========================================================================
// universal lifecycle helpers
// =========================================================================

const UNIVERSAL_SUBNET: &str = "172.57.0.0/16";

fn resolve_cp_image(root: &Path, explicit: Option<&str>) -> Result<String, CliError> {
    if let Some(img) = explicit {
        return Ok(img.to_string());
    }
    // Check for locally-built kuma-cp image
    let check = run_command(
        &[
            "docker",
            "images",
            "--format",
            "{{.Repository}}:{{.Tag}}",
            "--filter",
            "reference=kuma-cp",
        ],
        None,
        None,
        &[0],
    )?;
    let first_line = check.stdout.lines().next().unwrap_or("").trim();
    if !first_line.is_empty() && first_line != "<none>:<none>" {
        return Ok(first_line.to_string());
    }
    // Build images from repo
    eprintln!("{} cluster: building kuma images", utc_now());
    run_command(&["make", "images"], Some(root), None, &[0])
        .map_err(|e| CliErrorKind::image_build_failed("make images").with_details(e.message()))?;
    // Re-check
    let recheck = run_command(
        &[
            "docker",
            "images",
            "--format",
            "{{.Repository}}:{{.Tag}}",
            "--filter",
            "reference=kuma-cp",
        ],
        None,
        None,
        &[0],
    )?;
    let img = recheck.stdout.lines().next().unwrap_or("").trim();
    if img.is_empty() || img == "<none>:<none>" {
        return Err(CliErrorKind::image_build_failed("kuma-cp image not found after build").into());
    }
    Ok(img.to_string())
}

fn universal_single_up(
    image: &str,
    network: &str,
    store: &str,
    cp_name: &str,
) -> Result<UniversalUpResult, CliError> {
    docker_network_create(network, UNIVERSAL_SUBNET)?;

    let env = [
        ("KUMA_ENVIRONMENT", "universal"),
        ("KUMA_MODE", "zone"),
        ("KUMA_STORE_TYPE", store),
    ];
    docker_run_detached(
        image,
        cp_name,
        network,
        &env,
        &[(5681, 5681), (5678, 5678)],
        &[],
        &["run"],
    )?;

    let ip = docker_inspect_ip(cp_name, network)?;
    let health_url = format!("http://{ip}:5681");
    eprintln!("{} cluster: waiting for CP at {health_url}", utc_now());
    wait_for_http(&health_url, Duration::from_mins(1))?;

    let admin_token = extract_admin_token(cp_name)?;
    eprintln!(
        "{} cluster: CP ready at {health_url} (admin token extracted)",
        utc_now()
    );
    Ok(UniversalUpResult {
        admin_token,
        cp_ip: ip,
    })
}

fn universal_single_down(network: &str, cp_name: &str) -> Result<(), CliError> {
    docker_rm(cp_name)?;
    docker_network_rm(network)?;
    Ok(())
}

fn universal_global_zone_up(
    image: &str,
    network: &str,
    store: &str,
    names: &[String],
) -> Result<UniversalUpResult, CliError> {
    if names.len() < 3 {
        return Err(CliErrorKind::usage_error(
            "global-zone-up requires names: <global> <zone-container> <zone-label>",
        )
        .into());
    }
    let global_name = &names[0];
    let zone_name = &names[1];
    let zone_label = &names[2];

    // Compose manages its own network - don't pre-create
    let compose_file = compose::global_zone(
        image,
        network,
        UNIVERSAL_SUBNET,
        store,
        global_name,
        zone_name,
        zone_label,
    );
    let tmp_dir = tempfile::tempdir().map_err(|e| CliErrorKind::io(cow!("temp dir: {e}")))?;
    let compose_path = tmp_dir.path().join("docker-compose.yaml");
    compose_file.write_to(&compose_path)?;

    let project = format!("harness-{global_name}");
    compose_up(&compose_path, &project)?;

    let compose_network = format!("{project}_{network}");
    let global_container = format!("{project}-{global_name}-1");
    let global_ip = docker_inspect_ip(&global_container, &compose_network)?;

    let global_url = format!("http://{global_ip}:5681");
    eprintln!(
        "{} cluster: waiting for global CP at {global_url}",
        utc_now()
    );
    wait_for_http(&global_url, Duration::from_mins(1))?;

    let admin_token = extract_admin_token(&global_container)?;
    eprintln!(
        "{} cluster: global CP ready (admin token extracted)",
        utc_now()
    );

    Ok(UniversalUpResult {
        admin_token,
        cp_ip: global_ip,
    })
}

fn universal_global_zone_down(_network: &str, names: &[String]) -> Result<(), CliError> {
    let global_name = &names[0];
    let project = format!("harness-{global_name}");
    compose_down_project(&project)?;
    Ok(())
}

fn universal_global_two_zones_up(
    image: &str,
    network: &str,
    store: &str,
    names: &[String],
) -> Result<UniversalUpResult, CliError> {
    if names.len() < 5 {
        return Err(CliErrorKind::usage_error(
            "global-two-zones-up requires names: <global> <zone1-container> <zone2-container> <zone1-label> <zone2-label>",
        )
        .into());
    }
    let global_name = &names[0];
    let zone1_name = &names[1];
    let zone2_name = &names[2];
    let zone1_label = &names[3];
    let zone2_label = &names[4];

    // Compose manages its own network - don't pre-create
    let compose_file = compose::global_two_zones(compose::GlobalTwoZonesConfig {
        image,
        network_name: network,
        subnet: UNIVERSAL_SUBNET,
        store_type: store,
        global_name,
        zone1: compose::ZoneConfig {
            name: zone1_name,
            label: zone1_label,
        },
        zone2: compose::ZoneConfig {
            name: zone2_name,
            label: zone2_label,
        },
    });
    let tmp_dir = tempfile::tempdir().map_err(|e| CliErrorKind::io(cow!("temp dir: {e}")))?;
    let compose_path = tmp_dir.path().join("docker-compose.yaml");
    compose_file.write_to(&compose_path)?;

    let project = format!("harness-{global_name}");
    compose_up(&compose_path, &project)?;

    let compose_network = format!("{project}_{network}");
    let global_container = format!("{project}-{global_name}-1");
    let global_ip = docker_inspect_ip(&global_container, &compose_network)?;

    let global_url = format!("http://{global_ip}:5681");
    eprintln!(
        "{} cluster: waiting for global CP at {global_url}",
        utc_now()
    );
    wait_for_http(&global_url, Duration::from_mins(1))?;

    let admin_token = extract_admin_token(&global_container)?;
    eprintln!(
        "{} cluster: global CP ready (admin token extracted)",
        utc_now()
    );

    Ok(UniversalUpResult {
        admin_token,
        cp_ip: global_ip,
    })
}

fn universal_global_two_zones_down(_network: &str, names: &[String]) -> Result<(), CliError> {
    let global_name = &names[0];
    let project = format!("harness-{global_name}");
    compose_down_project(&project)?;
    Ok(())
}
