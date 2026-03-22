use std::path::PathBuf;
use std::time::Duration;

use tracing::info;

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
    let (_tmp_dir, compose_path) = write_compose_file(&compose_file)?;

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
    let admin_token = token::extract_admin_token(docker, &container)?;
    info!(%health_url, "CP ready (admin token extracted)");
    Ok(UniversalUpResult {
        admin_token,
        cp_ip: ip,
    })
}

pub(super) fn universal_global_zone_up(
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

    let compose_file = compose::global_zone(
        image,
        network,
        UNIVERSAL_SUBNET,
        store,
        global_name,
        zone_name,
        zone_label,
    );
    let (_tmp_dir, compose_path) = write_compose_file(&compose_file)?;

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
    let admin_token = token::extract_admin_token(docker, &global_container)?;
    info!("global CP ready (admin token extracted)");

    Ok(UniversalUpResult {
        admin_token,
        cp_ip: global_ip,
    })
}

pub(super) fn universal_global_two_zones_up(
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
    let (_tmp_dir, compose_path) = write_compose_file(&compose_file)?;

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
    let admin_token = token::extract_admin_token(docker, &global_container)?;
    info!("global CP ready (admin token extracted)");

    Ok(UniversalUpResult {
        admin_token,
        cp_ip: global_ip,
    })
}

pub(super) fn universal_global_zone_down(
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

pub(super) fn universal_global_two_zones_down(
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
