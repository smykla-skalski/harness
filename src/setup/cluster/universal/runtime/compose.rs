use std::path::PathBuf;
use std::time::Duration;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::token;
use crate::infra::blocks::{ComposeOrchestrator, ContainerRuntime};
use crate::infra::exec::wait_for_http;
use crate::platform::compose::{self, ComposeFile};

use super::{UNIVERSAL_SUBNET, UniversalUpResult};

fn write_compose_file(
    compose_file: &ComposeFile,
) -> Result<(tempfile::TempDir, PathBuf), CliError> {
    let tmp_dir =
        tempfile::tempdir().map_err(|error| CliErrorKind::io(format!("temp dir: {error}")))?;
    let compose_path = tmp_dir.path().join("docker-compose.yaml");
    compose_file.write_to(&compose_path)?;
    Ok((tmp_dir, compose_path))
}

pub(super) fn universal_single_up_compose(
    image: &str,
    network: &str,
    store: &str,
    cp_name: &str,
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<UniversalUpResult, CliError> {
    let compose_file = compose::single_zone(image, network, UNIVERSAL_SUBNET, store, cp_name);
    let project = format!("harness-{cp_name}");
    start_compose_project(&compose_file, &project, compose_runtime)?;
    compose_up_result(docker, &project, network, cp_name)
}

pub(super) fn universal_global_zone_up(
    image: &str,
    network: &str,
    store: &str,
    names: &[String],
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<UniversalUpResult, CliError> {
    ensure_minimum_names(
        names,
        3,
        "global-zone-up requires names: <global> <zone-container> <zone-label>",
    )?;
    let global_name = &names[0];
    let zone_name = &names[1];
    let zone_label = &names[2];

    let compose_file = compose::global_zone(
        image,
        network,
        UNIVERSAL_SUBNET,
        store,
        global_name,
        zone_name,
        zone_label,
    );
    let project = format!("harness-{global_name}");
    start_compose_project(&compose_file, &project, compose_runtime)?;
    compose_up_result(docker, &project, network, global_name)
}

pub(super) fn universal_global_two_zones_up(
    image: &str,
    network: &str,
    store: &str,
    names: &[String],
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<UniversalUpResult, CliError> {
    ensure_minimum_names(
        names,
        5,
        "global-two-zones-up requires names: <global> <zone1-container> <zone2-container> <zone1-label> <zone2-label>",
    )?;
    let global_name = &names[0];
    let zone1_name = &names[1];
    let zone2_name = &names[2];
    let zone1_label = &names[3];
    let zone2_label = &names[4];

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
    let project = format!("harness-{global_name}");
    start_compose_project(&compose_file, &project, compose_runtime)?;
    compose_up_result(docker, &project, network, global_name)
}

pub(super) fn universal_global_zone_down(
    names: &[String],
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    compose_global_down(names, docker, compose_runtime)
}

pub(super) fn universal_global_two_zones_down(
    names: &[String],
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    compose_global_down(names, docker, compose_runtime)
}

fn ensure_minimum_names(names: &[String], minimum: usize, message: &str) -> Result<(), CliError> {
    if names.len() >= minimum {
        return Ok(());
    }
    Err(CliErrorKind::usage_error(message.to_string()).into())
}

fn start_compose_project(
    compose_file: &ComposeFile,
    project: &str,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    let (_tmp_dir, compose_path) = write_compose_file(compose_file)?;
    compose_runtime.up(&compose_path, project, Duration::from_mins(3))?;
    Ok(())
}

fn compose_up_result(
    docker: &dyn ContainerRuntime,
    project: &str,
    network: &str,
    global_name: &str,
) -> Result<UniversalUpResult, CliError> {
    let compose_network = format!("{project}_{network}");
    let container = format!("{project}-{global_name}-1");
    let ip = docker.inspect_ip(&container, &compose_network)?;
    let health_url = format!("http://{ip}:5681");
    wait_for_http(&health_url, Duration::from_mins(1))?;
    let admin_token = token::extract_admin_token(docker, &container)?;
    Ok(UniversalUpResult {
        admin_token,
        cp_ip: ip,
    })
}

fn compose_global_down(
    names: &[String],
    docker: &dyn ContainerRuntime,
    compose_runtime: &dyn ComposeOrchestrator,
) -> Result<(), CliError> {
    let _ = docker.remove_by_label("io.harness.service=true")?;
    let project = format!("harness-{}", names[0]);
    compose_runtime.down_project(&project)?;
    Ok(())
}
