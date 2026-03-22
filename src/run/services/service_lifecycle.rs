use std::thread;
use std::time::Duration;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::defaults;
use crate::infra::blocks::kuma::service::{KumaService, KumaServiceSpec};
use crate::infra::blocks::kuma::token::parse_token_response;
use crate::infra::blocks::{ContainerConfig, ContainerPort, ContainerRuntime};
use crate::infra::exec::{self, CommandResult};
use crate::kernel::topology::UNIVERSAL_PUBLISHED_HOST;
use crate::platform::runtime::ControlPlaneAccess;
use crate::platform::runtime::XdsAccess;

use super::status::ServiceStatusRecord;

#[derive(Debug, Clone)]
pub struct StartServiceRequest<'a> {
    pub name: &'a str,
    pub image: Option<&'a str>,
    pub port: u16,
    pub mesh: &'a str,
    pub transparent_proxy: bool,
    pub timeout: u64,
}

struct ServiceSetup<'a> {
    docker: &'a dyn ContainerRuntime,
    name: &'a str,
    port: u16,
    mesh: &'a str,
    network: &'a str,
    token: &'a str,
    transparent_proxy: bool,
    timeout: u64,
    xds: XdsAccess<'a>,
}

const TEMPLATE_DATAPLANE: &str =
    include_str!("../../../resources/universal/templates/dataplane.yaml.j2");
const TEMPLATE_TRANSPARENT_PROXY: &str =
    include_str!("../../../resources/universal/templates/transparent-proxy.yaml.j2");

#[must_use]
pub(crate) const fn service_probe_port() -> u16 {
    defaults::ENVOY_ADMIN_PORT
}

#[must_use]
pub(crate) fn service_container_ports(service_port: u16) -> Vec<ContainerPort> {
    vec![
        ContainerPort::fixed(service_port, service_port),
        ContainerPort::ephemeral(service_probe_port()),
    ]
}

#[must_use]
pub(crate) fn run_service_filter(run_id: &str) -> String {
    format!("label=io.harness.run-id={run_id}")
}

/// List service containers scoped to the current run.
///
/// # Errors
/// Returns `CliError` on docker invocation failures.
pub(crate) fn read_service_container_rows(
    docker: &dyn ContainerRuntime,
    filter: &str,
) -> Result<Vec<ServiceStatusRecord>, CliError> {
    let result = docker.list_formatted(&["--filter", filter], "{{.Names}}\t{{.Status}}")?;
    Ok(result
        .stdout
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let mut parts = line.splitn(2, '\t');
            ServiceStatusRecord {
                name: parts.next().unwrap_or_default().to_string(),
                status: parts.next().unwrap_or_default().to_string(),
            }
        })
        .collect())
}

/// Start a tracked universal service container and attach a Kuma dataplane.
///
/// # Errors
/// Returns `CliError` when the tracked run is missing universal access details
/// or when container setup fails.
pub(crate) fn start_tracked_service_container(
    docker: &dyn ContainerRuntime,
    run_id: &str,
    access: &ControlPlaneAccess<'_>,
    xds: XdsAccess<'_>,
    network: &str,
    service_image: &str,
    request: &StartServiceRequest<'_>,
) -> Result<(), CliError> {
    let token = token_via_api(
        access.addr.as_ref(),
        request.name,
        request.mesh,
        defaults::DEFAULT_TOKEN_VALID_FOR,
        access.admin_token,
    )?;

    docker.run_detached(&ContainerConfig {
        image: service_image.to_string(),
        name: request.name.to_string(),
        network: network.to_string(),
        env: vec![],
        ports: service_container_ports(request.port),
        labels: vec![
            ("io.harness.service".to_string(), "true".to_string()),
            ("io.harness.run-id".to_string(), run_id.to_string()),
        ],
        entrypoint: None,
        restart_policy: None,
        extra_args: vec![],
        command: vec!["sleep".to_string(), "infinity".to_string()],
    })?;

    if let Err(error) = service_up_inner(&ServiceSetup {
        docker,
        name: request.name,
        port: request.port,
        mesh: request.mesh,
        network,
        token: token.trim(),
        transparent_proxy: request.transparent_proxy,
        timeout: request.timeout,
        xds,
    }) {
        let _ = docker.remove(request.name);
        return Err(error);
    }

    Ok(())
}

/// Read or stream logs for a tracked cluster container.
///
/// Returns `None` when logs are streamed directly to the terminal.
///
/// # Errors
/// Returns `CliError` on docker invocation failures.
pub(crate) fn read_service_logs(
    docker: &dyn ContainerRuntime,
    container: &str,
    tail: u32,
    follow: bool,
) -> Result<Option<CommandResult>, CliError> {
    let tail_str = tail.to_string();
    let mut args: Vec<&str> = vec!["--tail", &tail_str];
    if follow {
        args.push("-f");
        docker.logs_follow(container, &args)?;
        return Ok(None);
    }

    Ok(Some(ContainerRuntime::logs(docker, container, &args)?))
}

fn service_up_inner(setup: &ServiceSetup<'_>) -> Result<(), CliError> {
    let container_address = setup.docker.inspect_ip(setup.name, setup.network)?;
    let files = KumaService::files_for(setup.name);
    let (template_name, template_content) = if setup.transparent_proxy {
        ("transparent-proxy.yaml.j2", TEMPLATE_TRANSPARENT_PROXY)
    } else {
        ("dataplane.yaml.j2", TEMPLATE_DATAPLANE)
    };
    let dataplane_yaml = KumaService::render_dataplane_template(
        template_name,
        template_content,
        &KumaServiceSpec {
            name: setup.name.to_string(),
            mesh: setup.mesh.to_string(),
            address: container_address,
            port: setup.port,
            transparent_proxy: setup.transparent_proxy,
        },
    )
    .map_err(|error| CliErrorKind::template_render(error.to_string()))?;

    let ca_cert = thread::scope(|scope| {
        let token_write = scope.spawn(|| {
            setup
                .docker
                .write_file(setup.name, &files.token_path, setup.token)
        });
        let yaml_write = scope.spawn(|| {
            setup
                .docker
                .write_file(setup.name, &files.dataplane_path, &dataplane_yaml)
        });
        let cert_extract = scope.spawn(|| extract_cp_ca_cert(setup.xds));
        token_write.join().expect("token write thread panicked")?;
        yaml_write.join().expect("yaml write thread panicked")?;
        cert_extract.join().expect("cert extract thread panicked")
    })?;

    if setup.transparent_proxy {
        setup.docker.exec_command(
            setup.name,
            &["kumactl", "install", "transparent-proxy", "--redirect-dns"],
        )?;
    }

    setup
        .docker
        .write_file(setup.name, &files.ca_cert_path, &ca_cert)?;

    let launch = KumaService::launch_for(setup.name, &files, setup.xds);
    let launch_args = launch.args.iter().map(String::as_str).collect::<Vec<_>>();
    setup.docker.exec_detached(setup.name, &launch_args)?;

    let readiness_port = setup
        .docker
        .inspect_host_port(setup.name, service_probe_port())?;
    let readiness_url = KumaService::readiness_url(UNIVERSAL_PUBLISHED_HOST, readiness_port);
    exec::wait_for_http(&readiness_url, Duration::from_secs(setup.timeout))
        .map_err(|_| CliErrorKind::service_readiness_timeout(setup.name.to_string()).into())
}

fn token_via_api(
    addr: &str,
    name: &str,
    mesh: &str,
    valid_for: &str,
    admin_token: Option<&str>,
) -> Result<String, CliError> {
    let body = serde_json::json!({
        "name": name,
        "mesh": mesh,
        "type": "dataplane",
        "validFor": valid_for,
    });
    let token = exec::cp_api_text(
        addr,
        "/tokens/dataplane",
        exec::HttpMethod::Post,
        Some(&body),
        admin_token,
    )?;
    parse_token_response(&token)
        .map(|response| response.token)
        .map_err(|error| CliErrorKind::token_generation_failed(error.to_string()).into())
}

fn extract_cp_ca_cert(xds: XdsAccess<'_>) -> Result<String, CliError> {
    let connect_arg = format!("{UNIVERSAL_PUBLISHED_HOST}:{}", xds.host_port);
    let result = exec::run_command(
        &[
            "openssl",
            "s_client",
            "-connect",
            &connect_arg,
            "-showcerts",
        ],
        None,
        None,
        &[0, 1],
    )?;
    let cert = extract_pem_certificates(&result.stdout);
    if cert.is_empty() {
        return Err(CliErrorKind::cp_api_unreachable(format!(
            "could not extract CA cert from {connect_arg}"
        ))
        .into());
    }
    Ok(cert)
}

pub(crate) fn extract_pem_certificates(output: &str) -> String {
    let mut result = String::new();
    let mut in_cert = false;
    for line in output.lines() {
        if line.contains("BEGIN CERTIFICATE") {
            in_cert = true;
        }
        if in_cert {
            result.push_str(line);
            result.push('\n');
        }
        if line.contains("END CERTIFICATE") {
            in_cert = false;
        }
    }
    result.trim().to_string()
}
