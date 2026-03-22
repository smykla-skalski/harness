use std::time::Duration;

use crate::errors::CliError;
use crate::infra::blocks::ContainerPort;
use crate::infra::blocks::kuma::defaults;
use crate::infra::blocks::kuma::token;
use crate::infra::blocks::{ComposeOrchestrator, ContainerConfig, ContainerRuntime};
use crate::infra::exec::wait_for_http;
use crate::kernel::topology::{ClusterMode, ClusterSpec, UNIVERSAL_PUBLISHED_HOST};
use crate::workspace::HARNESS_PREFIX;

#[path = "runtime/compose.rs"]
mod compose_runtime;

const UNIVERSAL_SUBNET: &str = "172.57.0.0/16";

/// Result from a universal cluster up operation.
pub(super) struct UniversalUpResult {
    admin_token: String,
    members: Vec<UniversalMemberRuntime>,
}

pub(super) struct UniversalMemberRuntime {
    name: String,
    container_ip: String,
    cp_api_port: u16,
    xds_port: Option<u16>,
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
    remove_service_containers(docker)?;
    if effective_store == "postgres" {
        return down_compose_project(compose_runtime, cluster_name);
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
    for runtime in result.members {
        if let Some(member) = spec
            .members
            .iter_mut()
            .find(|member| member.name == runtime.name)
        {
            member.container_ip = Some(runtime.container_ip);
            member.cp_api_port = Some(runtime.cp_api_port);
            member.xds_port = runtime.xds_port;
        }
    }
}

fn universal_single_up(
    image: &str,
    network: &str,
    store: &str,
    cp_name: &str,
    docker: &dyn ContainerRuntime,
) -> Result<UniversalUpResult, CliError> {
    docker.create_network(network, UNIVERSAL_SUBNET)?;
    docker.run_detached(&single_zone_container_config(
        image, network, store, cp_name,
    ))?;
    build_universal_up_result(docker, cp_name, network)
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

fn remove_service_containers(docker: &dyn ContainerRuntime) -> Result<(), CliError> {
    let _ = docker.remove_by_label("io.harness.service=true")?;
    Ok(())
}

fn down_compose_project(
    compose_runtime: &dyn ComposeOrchestrator,
    cluster_name: &str,
) -> Result<(), CliError> {
    let project = format!("{HARNESS_PREFIX}{cluster_name}");
    compose_runtime.down_project(&project)?;
    Ok(())
}

fn single_zone_container_config(
    image: &str,
    network: &str,
    store: &str,
    cp_name: &str,
) -> ContainerConfig {
    ContainerConfig {
        image: image.to_string(),
        name: cp_name.to_string(),
        network: network.to_string(),
        env: vec![
            ("KUMA_ENVIRONMENT".to_string(), "universal".to_string()),
            ("KUMA_MODE".to_string(), "zone".to_string()),
            ("KUMA_STORE_TYPE".to_string(), store.to_string()),
        ],
        ports: vec![
            ContainerPort::fixed(defaults::CP_API_PORT, defaults::CP_API_PORT),
            ContainerPort::fixed(defaults::XDS_PORT, defaults::XDS_PORT),
        ],
        labels: vec![],
        entrypoint: None,
        restart_policy: None,
        extra_args: vec![],
        command: vec!["run".to_string()],
    }
}

fn build_universal_up_result(
    docker: &dyn ContainerRuntime,
    cp_name: &str,
    network: &str,
) -> Result<UniversalUpResult, CliError> {
    let ip = docker.inspect_ip(cp_name, network)?;
    let health_url = format!(
        "http://{UNIVERSAL_PUBLISHED_HOST}:{}",
        defaults::CP_API_PORT
    );
    wait_for_http(&health_url, Duration::from_mins(1))?;
    let admin_token = token::extract_admin_token(docker, cp_name)?;
    Ok(UniversalUpResult {
        admin_token,
        members: vec![UniversalMemberRuntime {
            name: cp_name.to_string(),
            container_ip: ip,
            cp_api_port: defaults::CP_API_PORT,
            xds_port: Some(defaults::XDS_PORT),
        }],
    })
}
