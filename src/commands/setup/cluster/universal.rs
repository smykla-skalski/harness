use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use tracing::{info, warn};

use crate::blocks::{
    ComposeOrchestrator, ContainerConfig, ContainerRuntime, DockerComposeOrchestrator,
    DockerContainerRuntime, StdProcessExecutor,
};
use crate::cluster::{ClusterSpec, Platform};
use crate::commands::resolve_repo_root;
use crate::compose;
use crate::context::RunRepository;
use crate::core_defs::HARNESS_PREFIX;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::exec::{extract_admin_token, run_command, wait_for_http};

use super::{ClusterArgs, persist_cluster_spec};

const UNIVERSAL_SUBNET: &str = "172.57.0.0/16";

/// Docker filter patterns for finding kuma-cp images. The glob `*kuma-cp`
/// matches both bare `kuma-cp` and namespaced `kumahq/kuma-cp` repositories.
pub(super) const KUMA_CP_IMAGE_FILTERS: &[&str] = &["reference=*kuma-cp", "reference=kuma-cp"];

/// Result from a universal cluster up operation.
struct UniversalUpResult {
    admin_token: String,
    cp_ip: String,
}

/// Search for a local kuma-cp image using multiple reference filters.
///
/// Docker's `--filter reference=` doesn't glob across namespaces the same
/// way in all versions, so we try the namespaced glob first and fall back
/// to the bare name.
fn find_local_kuma_cp_image() -> Result<Option<String>, CliError> {
    for filter in KUMA_CP_IMAGE_FILTERS {
        let result = run_command(
            &[
                "docker",
                "images",
                "--format",
                "{{.Repository}}:{{.Tag}}",
                "--filter",
                filter,
            ],
            None,
            None,
            &[0],
        )?;
        let first_line = result.stdout.lines().next().unwrap_or("").trim();
        if !first_line.is_empty() && first_line != "<none>:<none>" {
            return Ok(Some(first_line.to_string()));
        }
    }
    Ok(None)
}

pub(super) fn resolve_cp_image(
    root: &Path,
    explicit: Option<&str>,
    skip_build: bool,
) -> Result<String, CliError> {
    if let Some(img) = explicit {
        return Ok(img.to_string());
    }

    // Check for locally-built kuma-cp image
    if let Some(found) = find_local_kuma_cp_image()? {
        return Ok(found);
    }

    if skip_build {
        return Err(CliErrorKind::image_build_failed(
            "kuma-cp image not found and --no-build was specified",
        )
        .into());
    }

    // Build images from repo
    info!("building kuma images");
    run_command(&["make", "images"], Some(root), None, &[0])
        .map_err(|e| CliErrorKind::image_build_failed("make images").with_details(e.message()))?;

    // Re-check after build
    find_local_kuma_cp_image()?.ok_or_else(|| {
        CliErrorKind::image_build_failed("kuma-cp image not found after build").into()
    })
}

/// Resolve the effective store type for a cluster operation.
///
/// For `up` operations, uses the CLI-supplied store directly.
/// For `down` operations, checks the persisted spec first and falls back to CLI.
pub(super) fn resolve_effective_store(is_up: bool, cli_store: &str) -> String {
    if is_up {
        return cli_store.to_string();
    }
    match load_persisted_cluster_spec() {
        Ok(Some(spec)) => spec.store_type.unwrap_or_else(|| cli_store.to_string()),
        Ok(None) => cli_store.to_string(),
        Err(e) => {
            warn!(%e, "failed to load persisted cluster spec");
            cli_store.to_string()
        }
    }
}

/// Load persisted cluster spec from the session context file.
///
/// # Errors
/// Returns `CliError` on corrupt JSON or parse failures. Returns `Ok(None)` when
/// the context file is missing.
pub(super) fn load_persisted_cluster_spec() -> Result<Option<ClusterSpec>, CliError> {
    let repo = RunRepository;
    Ok(repo
        .load_current_pointer()?
        .and_then(|pointer| pointer.cluster))
}

pub(super) fn cluster_universal(args: &ClusterArgs) -> Result<i32, CliError> {
    let mode = &args.mode;
    let mut all_names = vec![args.cluster_name.clone()];
    all_names.extend(args.extra_cluster_names.iter().cloned());

    let root = resolve_repo_root(args.repo_root.as_deref());

    let mut spec = ClusterSpec::from_mode_with_platform(
        mode,
        &all_names,
        &root.to_string_lossy(),
        vec![],
        vec![],
        Platform::Universal,
    )
    .map_err(|e| CliError::from(CliErrorKind::cluster_error(e)))?;

    let network_name = spec
        .docker_network
        .clone()
        .unwrap_or_else(|| "harness-default".to_string());
    let is_up = spec.mode.is_up();

    let effective_store = resolve_effective_store(is_up, &args.store);
    let cp_image = resolve_universal_cp_image(is_up, &root, args.image.as_deref(), args.no_build)?;
    let process = Arc::new(StdProcessExecutor);
    let docker = DockerContainerRuntime::new(process.clone());
    let compose_runtime = DockerComposeOrchestrator::new(process);

    info!(%mode, names = %all_names.join(" "), "starting universal cluster");

    execute_universal_mode(
        &UniversalModeContext {
            mode,
            all_names: &all_names,
            network_name: &network_name,
            effective_store: &effective_store,
            cp_image: &cp_image,
        },
        &mut spec,
        &docker,
        &compose_runtime,
    )?;

    if is_up {
        persist_cluster_spec(&spec)?;
    }

    println!("{mode} completed");
    Ok(0)
}

fn resolve_universal_cp_image(
    is_up: bool,
    root: &Path,
    explicit: Option<&str>,
    skip_build: bool,
) -> Result<String, CliError> {
    if is_up {
        return resolve_cp_image(root, explicit, skip_build);
    }
    Ok(String::new())
}

struct UniversalModeContext<'a> {
    mode: &'a str,
    all_names: &'a [String],
    network_name: &'a str,
    effective_store: &'a str,
    cp_image: &'a str,
}

fn execute_universal_mode(
    context: &UniversalModeContext<'_>,
    spec: &mut ClusterSpec,
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    match context.mode {
        "single-up" => handle_single_up(
            spec,
            context.cp_image,
            context.network_name,
            context.effective_store,
            &context.all_names[0],
            docker,
            compose_runtime,
        ),
        "single-down" => handle_single_down(
            context.network_name,
            context.effective_store,
            &context.all_names[0],
            docker,
            compose_runtime,
        ),
        "global-zone-up" => handle_global_zone_up(
            spec,
            context.cp_image,
            context.network_name,
            context.effective_store,
            context.all_names,
            docker,
            compose_runtime,
        ),
        "global-zone-down" => universal_global_zone_down(
            context.network_name,
            context.all_names,
            docker,
            compose_runtime,
        ),
        "global-two-zones-up" => handle_global_two_zones_up(
            spec,
            context.cp_image,
            context.network_name,
            context.effective_store,
            context.all_names,
            docker,
            compose_runtime,
        ),
        "global-two-zones-down" => universal_global_two_zones_down(
            context.network_name,
            context.all_names,
            docker,
            compose_runtime,
        ),
        _ => Err(
            CliErrorKind::cluster_error(cow!("unsupported cluster mode: {}", context.mode)).into(),
        ),
    }
}

fn handle_single_up(
    spec: &mut ClusterSpec,
    cp_image: &str,
    network_name: &str,
    effective_store: &str,
    cluster_name: &str,
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    let result = if effective_store == "postgres" {
        universal_single_up_compose(
            cp_image,
            network_name,
            effective_store,
            cluster_name,
            docker,
            compose_runtime,
        )?
    } else {
        universal_single_up(
            cp_image,
            network_name,
            effective_store,
            cluster_name,
            docker,
        )?
    };
    apply_universal_up_result(spec, cp_image, effective_store, result);
    Ok(())
}

fn handle_single_down(
    network_name: &str,
    effective_store: &str,
    cluster_name: &str,
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    let removed = docker.remove_by_label("io.harness.service=true")?;
    for name in &removed {
        info!(%name, "removed service container");
    }
    if effective_store == "postgres" {
        let project = format!("{HARNESS_PREFIX}{cluster_name}");
        compose_runtime.down_project(&project)?;
        return Ok(());
    }
    universal_single_down(network_name, cluster_name, docker)
}

fn handle_global_zone_up(
    spec: &mut ClusterSpec,
    cp_image: &str,
    network_name: &str,
    effective_store: &str,
    all_names: &[String],
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    let result = universal_global_zone_up(
        cp_image,
        network_name,
        effective_store,
        all_names,
        docker,
        compose_runtime,
    )?;
    apply_universal_up_result(spec, cp_image, effective_store, result);
    Ok(())
}

fn handle_global_two_zones_up(
    spec: &mut ClusterSpec,
    cp_image: &str,
    network_name: &str,
    effective_store: &str,
    all_names: &[String],
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    let result = universal_global_two_zones_up(
        cp_image,
        network_name,
        effective_store,
        all_names,
        docker,
        compose_runtime,
    )?;
    apply_universal_up_result(spec, cp_image, effective_store, result);
    Ok(())
}

fn apply_universal_up_result(
    spec: &mut ClusterSpec,
    cp_image: &str,
    effective_store: &str,
    result: UniversalUpResult,
) {
    spec.cp_image = Some(cp_image.to_string());
    spec.store_type = Some(effective_store.to_string());
    spec.admin_token = Some(result.admin_token);
    spec.members[0].container_ip = Some(result.cp_ip);
}

fn universal_single_up(
    image: &str,
    network: &str,
    store: &str,
    cp_name: &str,
    docker: &dyn ContainerRuntime,
) -> Result<UniversalUpResult, CliError> {
    docker.create_network(network, UNIVERSAL_SUBNET)?;

    docker.run_detached(&ContainerConfig {
        image: image.to_string(),
        name: cp_name.to_string(),
        network: network.to_string(),
        env: vec![
            ("KUMA_ENVIRONMENT".to_string(), "universal".to_string()),
            ("KUMA_MODE".to_string(), "zone".to_string()),
            ("KUMA_STORE_TYPE".to_string(), store.to_string()),
        ],
        ports: vec![(5681, 5681), (5678, 5678)],
        labels: vec![],
        extra_args: vec![],
        command: vec!["run".to_string()],
    })?;

    let ip = docker.inspect_ip(cp_name, network)?;
    let health_url = format!("http://{ip}:5681");
    info!(%health_url, "waiting for CP");
    wait_for_http(&health_url, Duration::from_mins(1))?;

    info!("extracting admin token");
    let admin_token = extract_admin_token(cp_name)?;
    info!(%health_url, "CP ready (admin token extracted)");
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
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<UniversalUpResult, CliError> {
    let compose_file = compose::single_zone(image, network, UNIVERSAL_SUBNET, store, cp_name);
    let tmp_dir = tempfile::tempdir().map_err(|e| CliErrorKind::io(cow!("temp dir: {e}")))?;
    let compose_path = tmp_dir.path().join("docker-compose.yaml");
    compose_file.write_to(&compose_path)?;

    let project = format!("harness-{cp_name}");
    info!(%cp_name, "starting compose services");
    compose_runtime.up(&compose_path, &project, Duration::from_mins(3))?;
    info!(%cp_name, "compose services started");

    let compose_network = format!("{project}_{network}");
    let container = format!("{project}-{cp_name}-1");
    let ip = docker.inspect_ip(&container, &compose_network)?;

    let health_url = format!("http://{ip}:5681");
    info!(%health_url, "waiting for CP");
    wait_for_http(&health_url, Duration::from_mins(1))?;

    info!("extracting admin token");
    let admin_token = extract_admin_token(&container)?;
    info!(%health_url, "CP ready (admin token extracted)");
    Ok(UniversalUpResult {
        admin_token,
        cp_ip: ip,
    })
}

fn universal_single_down(
    network: &str,
    cp_name: &str,
    docker: &dyn ContainerRuntime,
) -> Result<(), CliError> {
    docker.remove(cp_name)?;
    docker.remove_network(network)?;
    Ok(())
}

fn universal_global_zone_up(
    image: &str,
    network: &str,
    store: &str,
    names: &[String],
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
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
    info!("starting compose services for global + zone");
    compose_runtime.up(&compose_path, &project, Duration::from_mins(3))?;
    info!("compose services started");

    let compose_network = format!("{project}_{network}");
    let global_container = format!("{project}-{global_name}-1");
    let global_ip = docker.inspect_ip(&global_container, &compose_network)?;

    let global_url = format!("http://{global_ip}:5681");
    info!(%global_url, "waiting for global CP");
    wait_for_http(&global_url, Duration::from_mins(1))?;

    info!("extracting admin token");
    let admin_token = extract_admin_token(&global_container)?;
    info!("global CP ready (admin token extracted)");

    Ok(UniversalUpResult {
        admin_token,
        cp_ip: global_ip,
    })
}

fn universal_global_zone_down(
    _network: &str,
    names: &[String],
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    let removed = docker.remove_by_label("io.harness.service=true")?;
    for name in &removed {
        info!(%name, "removed service container");
    }
    let global_name = &names[0];
    let project = format!("harness-{global_name}");
    compose_runtime.down_project(&project)?;
    Ok(())
}

fn universal_global_two_zones_up(
    image: &str,
    network: &str,
    store: &str,
    names: &[String],
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
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
    info!("starting compose services for global + two zones");
    compose_runtime.up(&compose_path, &project, Duration::from_mins(3))?;
    info!("compose services started");

    let compose_network = format!("{project}_{network}");
    let global_container = format!("{project}-{global_name}-1");
    let global_ip = docker.inspect_ip(&global_container, &compose_network)?;

    let global_url = format!("http://{global_ip}:5681");
    info!(%global_url, "waiting for global CP");
    wait_for_http(&global_url, Duration::from_mins(1))?;

    info!("extracting admin token");
    let admin_token = extract_admin_token(&global_container)?;
    info!("global CP ready (admin token extracted)");

    Ok(UniversalUpResult {
        admin_token,
        cp_ip: global_ip,
    })
}

fn universal_global_two_zones_down(
    _network: &str,
    names: &[String],
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    let removed = docker.remove_by_label("io.harness.service=true")?;
    for name in &removed {
        info!(%name, "removed service container");
    }
    let global_name = &names[0];
    let project = format!("harness-{global_name}");
    compose_runtime.down_project(&project)?;
    Ok(())
}
