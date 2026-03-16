use std::collections::HashMap;
use std::env;
use std::fs;
use std::io;
use std::path::Path;
use std::time::Duration;

use crate::cli::ClusterArgs;
use crate::cluster::{ClusterSpec, HelmSetting, Platform};
use crate::commands::resolve_repo_root;
use crate::compose;
use crate::context::CurrentRunRecord;
use crate::core_defs::{HARNESS_PREFIX, current_run_context_path, resolve_build_info, utc_now};
use crate::errors::{CliError, CliErrorKind, cow};
use crate::exec::{
    cluster_exists, compose_down_project, compose_up, docker, docker_inspect_ip,
    docker_network_create, docker_network_rm, docker_rm, docker_rm_by_label,
    docker_run_detached, extract_admin_token, kubectl, run_command, run_command_streaming,
    wait_for_http,
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
    eprintln!(
        "{} cluster: resolved global KDS address: {address}",
        utc_now()
    );
    Ok(address)
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

    if spec.mode.is_up() {
        persist_cluster_spec(&spec)?;
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

    let effective_store = resolve_effective_store(is_up, store);

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
            // Postgres needs Compose (for the postgres service); memory uses Docker CLI
            let result = if effective_store == "postgres" {
                universal_single_up_compose(
                    &cp_image,
                    network_name,
                    &effective_store,
                    &all_names[0],
                )?
            } else {
                universal_single_up(&cp_image, network_name, &effective_store, &all_names[0])?
            };
            spec.cp_image = Some(cp_image);
            spec.store_type = Some(effective_store);
            spec.admin_token = Some(result.admin_token);
            spec.members[0].container_ip = Some(result.cp_ip);
        }
        "single-down" => {
            let removed = docker_rm_by_label("io.harness.service=true")?;
            for name in &removed {
                eprintln!("{} cluster: removed service container {name}", utc_now());
            }
            if effective_store == "postgres" {
                // Compose-managed single-zone
                let project = format!("{HARNESS_PREFIX}{}", all_names[0]);
                compose_down_project(&project)?;
            } else {
                universal_single_down(network_name, &all_names[0])?;
            }
        }
        "global-zone-up" => {
            let result =
                universal_global_zone_up(&cp_image, network_name, &effective_store, &all_names)?;
            spec.cp_image = Some(cp_image);
            spec.store_type = Some(effective_store);
            spec.admin_token = Some(result.admin_token);
            spec.members[0].container_ip = Some(result.cp_ip);
        }
        "global-zone-down" => universal_global_zone_down(network_name, &all_names)?,
        "global-two-zones-up" => {
            let result = universal_global_two_zones_up(
                &cp_image,
                network_name,
                &effective_store,
                &all_names,
            )?;
            spec.cp_image = Some(cp_image);
            spec.store_type = Some(effective_store);
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

/// Resolve the effective store type for a cluster operation.
///
/// For `up` operations, uses the CLI-supplied store directly.
/// For `down` operations, checks the persisted spec first and falls back to CLI.
fn resolve_effective_store(is_up: bool, cli_store: &str) -> String {
    if is_up {
        return cli_store.to_string();
    }
    match load_persisted_cluster_spec() {
        Ok(Some(spec)) => spec.store_type.unwrap_or_else(|| cli_store.to_string()),
        Ok(None) => cli_store.to_string(),
        Err(e) => {
            eprintln!("warning: failed to load persisted cluster spec: {e}");
            cli_store.to_string()
        }
    }
}

/// Load persisted cluster spec from the session context file.
///
/// # Errors
/// Returns `CliError` on corrupt JSON or parse failures. Returns `Ok(None)` when
/// the context file is missing.
fn load_persisted_cluster_spec() -> Result<Option<ClusterSpec>, CliError> {
    let ctx_path = current_run_context_path()?;
    let text = match fs::read_to_string(&ctx_path) {
        Ok(t) => t,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(CliErrorKind::io(cow!("read {}: {e}", ctx_path.display())).into());
        }
    };
    let record: CurrentRunRecord = serde_json::from_str(&text)
        .map_err(|e| CliErrorKind::io(cow!("parse {}: {e}", ctx_path.display())))?;
    Ok(record.cluster)
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
    eprintln!(
        "{} cluster: global CP deployed, starting zone clusters",
        utc_now()
    );
    for (zone_cluster, zone_name) in [(&names[1], &names[3]), (&names[2], &names[4])] {
        eprintln!(
            "{} cluster: deploying zone {zone_name} on {zone_cluster}",
            utc_now()
        );
        let zone_settings = vec![
            "controlPlane.mode=zone".into(),
            format!("controlPlane.zone={zone_name}"),
            format!("controlPlane.kdsGlobalAddress={kds_address}"),
            "controlPlane.tls.kdsZoneClient.skipVerify=true".into(),
        ];
        start_and_deploy(root, base_env, zone_cluster, "zone", &zone_settings)?;
        eprintln!(
            "{} cluster: zone {zone_name} on {zone_cluster} ready",
            utc_now()
        );
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

    eprintln!("{} cluster: extracting admin token", utc_now());
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

fn universal_single_up_compose(
    image: &str,
    network: &str,
    store: &str,
    cp_name: &str,
) -> Result<UniversalUpResult, CliError> {
    let compose_file = compose::single_zone(image, network, UNIVERSAL_SUBNET, store, cp_name);
    let tmp_dir = tempfile::tempdir().map_err(|e| CliErrorKind::io(cow!("temp dir: {e}")))?;
    let compose_path = tmp_dir.path().join("docker-compose.yaml");
    compose_file.write_to(&compose_path)?;

    let project = format!("harness-{cp_name}");
    eprintln!(
        "{} cluster: starting compose services for {cp_name}",
        utc_now()
    );
    compose_up(&compose_path, &project, 180)?;
    eprintln!(
        "{} cluster: compose services for {cp_name} started",
        utc_now()
    );

    let compose_network = format!("{project}_{network}");
    let container = format!("{project}-{cp_name}-1");
    let ip = docker_inspect_ip(&container, &compose_network)?;

    let health_url = format!("http://{ip}:5681");
    eprintln!("{} cluster: waiting for CP at {health_url}", utc_now());
    wait_for_http(&health_url, Duration::from_mins(1))?;

    eprintln!("{} cluster: extracting admin token", utc_now());
    let admin_token = extract_admin_token(&container)?;
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
    eprintln!(
        "{} cluster: starting compose services for global + zone",
        utc_now()
    );
    compose_up(&compose_path, &project, 180)?;
    eprintln!("{} cluster: compose services started", utc_now());

    let compose_network = format!("{project}_{network}");
    let global_container = format!("{project}-{global_name}-1");
    let global_ip = docker_inspect_ip(&global_container, &compose_network)?;

    let global_url = format!("http://{global_ip}:5681");
    eprintln!(
        "{} cluster: waiting for global CP at {global_url}",
        utc_now()
    );
    wait_for_http(&global_url, Duration::from_mins(1))?;

    eprintln!("{} cluster: extracting admin token", utc_now());
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
    let removed = docker_rm_by_label("io.harness.service=true")?;
    for name in &removed {
        eprintln!("{} cluster: removed service container {name}", utc_now());
    }
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
    eprintln!(
        "{} cluster: starting compose services for global + two zones",
        utc_now()
    );
    compose_up(&compose_path, &project, 180)?;
    eprintln!("{} cluster: compose services started", utc_now());

    let compose_network = format!("{project}_{network}");
    let global_container = format!("{project}-{global_name}-1");
    let global_ip = docker_inspect_ip(&global_container, &compose_network)?;

    let global_url = format!("http://{global_ip}:5681");
    eprintln!(
        "{} cluster: waiting for global CP at {global_url}",
        utc_now()
    );
    wait_for_http(&global_url, Duration::from_mins(1))?;

    eprintln!("{} cluster: extracting admin token", utc_now());
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
    let removed = docker_rm_by_label("io.harness.service=true")?;
    for name in &removed {
        eprintln!("{} cluster: removed service container {name}", utc_now());
    }
    let global_name = &names[0];
    let project = format!("harness-{global_name}");
    compose_down_project(&project)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Compute the same scope key the production code uses for a given session ID.
    fn scope_key_for_session(session_id: &str) -> String {
        use sha2::{Digest, Sha256};
        let scope = format!("session:{session_id}");
        let mut hasher = Sha256::new();
        hasher.update(scope.as_bytes());
        let hash = hasher.finalize();
        let digest: String = hash.iter().take(8).map(|b| format!("{b:02x}")).collect();
        format!("session-{digest}")
    }

    fn write_context_file(xdg_dir: &std::path::Path, session_id: &str, content: &str) {
        let scope = scope_key_for_session(session_id);
        let ctx_dir = xdg_dir.join("kuma").join("contexts").join(scope);
        fs::create_dir_all(&ctx_dir).unwrap();
        fs::write(ctx_dir.join("current-run.json"), content).unwrap();
    }

    // --- resolve_effective_store tests ---

    #[test]
    fn effective_store_uses_cli_arg_for_up() {
        let tmp = tempfile::tempdir().unwrap();
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("eff-store-up")),
            ],
            || resolve_effective_store(true, "postgres"),
        );
        assert_eq!(result, "postgres");
    }

    #[test]
    fn effective_store_uses_persisted_for_down() {
        let tmp = tempfile::tempdir().unwrap();
        let session_id = "eff-store-down";
        let record = serde_json::json!({
            "layout": { "run_root": "/tmp/runs", "run_id": "r1" },
            "cluster": {
                "mode": "single-up",
                "platform": "universal",
                "mode_args": ["cp"],
                "members": [{"name": "cp", "role": "cp", "kubeconfig": ""}],
                "helm_settings": [],
                "restart_namespaces": [],
                "repo_root": "/r",
                "store_type": "postgres"
            }
        });
        write_context_file(
            tmp.path(),
            session_id,
            &serde_json::to_string(&record).unwrap(),
        );
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some(session_id)),
            ],
            || resolve_effective_store(false, "memory"),
        );
        assert_eq!(result, "postgres");
    }

    #[test]
    fn effective_store_falls_back_to_cli_for_down() {
        let tmp = tempfile::tempdir().unwrap();
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("eff-store-fallback")),
            ],
            || resolve_effective_store(false, "memory"),
        );
        assert_eq!(result, "memory");
    }

    // --- load_persisted_cluster_spec tests ---

    #[test]
    fn load_persisted_spec_none_when_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some("load-test-missing")),
            ],
            load_persisted_cluster_spec,
        );
        assert!(result.unwrap().is_none());
    }

    #[test]
    fn load_persisted_spec_err_when_corrupt() {
        let tmp = tempfile::tempdir().unwrap();
        let session_id = "load-test-corrupt";
        write_context_file(tmp.path(), session_id, "not valid json {{{{");
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some(session_id)),
            ],
            load_persisted_cluster_spec,
        );
        assert!(result.is_err());
    }

    #[test]
    fn load_persisted_spec_returns_cluster() {
        let tmp = tempfile::tempdir().unwrap();
        let session_id = "load-test-valid";
        let record = serde_json::json!({
            "layout": { "run_root": "/tmp/runs", "run_id": "r1" },
            "cluster": {
                "mode": "single-up",
                "platform": "universal",
                "mode_args": ["cp"],
                "members": [{"name": "cp", "role": "cp", "kubeconfig": ""}],
                "helm_settings": [],
                "restart_namespaces": [],
                "repo_root": "/r",
                "store_type": "postgres"
            }
        });
        write_context_file(
            tmp.path(),
            session_id,
            &serde_json::to_string(&record).unwrap(),
        );
        let result = temp_env::with_vars(
            [
                ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
                ("CLAUDE_SESSION_ID", Some(session_id)),
            ],
            load_persisted_cluster_spec,
        );
        let spec = result.unwrap().expect("should load cluster spec");
        assert_eq!(spec.store_type.as_deref(), Some("postgres"));
    }
}
