use std::time::Duration;

use tracing::info;

use crate::errors::CliError;
use crate::infra::blocks::kuma::token;
use crate::infra::blocks::{ComposeOrchestrator, ContainerConfig, ContainerRuntime};
use crate::infra::exec::wait_for_http;
use crate::kernel::topology::{ClusterMode, ClusterSpec};
use crate::workspace::HARNESS_PREFIX;

#[path = "runtime/compose.rs"]
mod compose_runtime;

const UNIVERSAL_SUBNET: &str = "172.57.0.0/16";

/// Result from a universal cluster up operation.
pub(super) struct UniversalUpResult {
    admin_token: String,
    cp_ip: String,
}

pub(super) struct UniversalModeContext<'a> {
    pub(super) mode: ClusterMode,
    pub(super) all_names: &'a [String],
    pub(super) network_name: &'a str,
    pub(super) effective_store: &'a str,
    pub(super) cp_image: &'a str,
}

pub(super) fn execute_universal_mode(
    context: &UniversalModeContext<'_>,
    spec: &mut ClusterSpec,
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    match context.mode {
        ClusterMode::SingleUp => handle_single_up(
            spec,
            context.cp_image,
            context.network_name,
            context.effective_store,
            &context.all_names[0],
            docker,
            compose_runtime,
        ),
        ClusterMode::SingleDown => handle_single_down(
            context.network_name,
            context.effective_store,
            &context.all_names[0],
            docker,
            compose_runtime,
        ),
        ClusterMode::GlobalZoneUp => handle_global_zone_up(
            spec,
            context.cp_image,
            context.network_name,
            context.effective_store,
            context.all_names,
            docker,
            compose_runtime,
        ),
        ClusterMode::GlobalZoneDown => {
            compose_runtime::universal_global_zone_down(context.all_names, docker, compose_runtime)
        }
        ClusterMode::GlobalTwoZonesUp => handle_global_two_zones_up(
            spec,
            context.cp_image,
            context.network_name,
            context.effective_store,
            context.all_names,
            docker,
            compose_runtime,
        ),
        ClusterMode::GlobalTwoZonesDown => compose_runtime::universal_global_two_zones_down(
            context.all_names,
            docker,
            compose_runtime,
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
        compose_runtime::universal_single_up_compose(
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
    let result = compose_runtime::universal_global_zone_up(
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
    let result = compose_runtime::universal_global_two_zones_up(
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
        entrypoint: None,
        restart_policy: None,
        extra_args: vec![],
        command: vec!["run".to_string()],
    })?;

    let ip = docker.inspect_ip(cp_name, network)?;
    let health_url = format!("http://{ip}:5681");
    info!(%health_url, "waiting for CP");
    wait_for_http(&health_url, Duration::from_mins(1))?;

    info!("extracting admin token");
    let admin_token = token::extract_admin_token(docker, cp_name)?;
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
