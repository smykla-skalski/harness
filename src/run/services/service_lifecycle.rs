use std::thread;
use std::time::Duration;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::defaults;
use crate::infra::blocks::kuma::service::{KumaService, KumaServiceSpec};
use crate::infra::blocks::kuma::token::parse_token_response;
use crate::infra::blocks::{ContainerConfig, ContainerRuntime};
use crate::infra::exec::{self, HttpMethod};
use crate::platform::runtime::XdsAccess;
use crate::run::state_capture::UniversalDataplaneCollection;

use super::RunServices;
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

impl RunServices {
    #[must_use]
    pub fn service_container_filter(&self) -> String {
        format!("label=io.harness.run-id={}", self.layout().run_id)
    }

    /// List service containers scoped to the current run.
    ///
    /// # Errors
    /// Returns `CliError` on docker invocation failures.
    pub fn list_service_containers(&self) -> Result<Vec<ServiceStatusRecord>, CliError> {
        let filter = self.service_container_filter();
        let result = self
            .docker()?
            .list_formatted(&["--filter", &filter], "{{.Names}}\t{{.Status}}")?;
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

    /// Query the control plane for dataplanes in the target mesh.
    ///
    /// # Errors
    /// Returns `CliError` when the control-plane request fails.
    pub fn query_dataplanes(&self, mesh: &str) -> Result<UniversalDataplaneCollection, CliError> {
        let path = format!("/meshes/{mesh}/dataplanes");
        self.call_control_plane_json(&path, HttpMethod::Get, None)
            .map(UniversalDataplaneCollection::from_api_value)
    }

    /// Start a tracked universal service container and attach a Kuma dataplane.
    ///
    /// # Errors
    /// Returns `CliError` when the tracked run is missing universal access details
    /// or when container setup fails.
    pub fn start_service(
        &self,
        docker: &dyn ContainerRuntime,
        request: &StartServiceRequest<'_>,
    ) -> Result<(), CliError> {
        let access = self.control_plane_access()?;
        let network = self.docker_network()?;
        let service_image = self.service_image(request.image)?;
        let token = token_via_api(
            access.addr.as_ref(),
            request.name,
            request.mesh,
            defaults::DEFAULT_TOKEN_VALID_FOR,
            access.admin_token,
        )?;

        docker.run_detached(&ContainerConfig {
            image: service_image.into_owned(),
            name: request.name.to_string(),
            network: network.to_string(),
            env: vec![],
            ports: vec![(request.port, request.port)],
            labels: vec![
                ("io.harness.service".to_string(), "true".to_string()),
                (
                    "io.harness.run-id".to_string(),
                    self.layout().run_id.clone(),
                ),
            ],
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
            xds: self.xds_access()?,
        }) {
            let _ = docker.remove(request.name);
            return Err(error);
        }

        Ok(())
    }
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
            address: container_address.clone(),
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
        let cert_extract = scope.spawn(|| extract_cp_ca_cert(setup.xds.ip, setup.xds.port));
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

    let readiness_url = KumaService::readiness_url(&container_address);
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

fn extract_cp_ca_cert(cp_ip: &str, xds_port: u16) -> Result<String, CliError> {
    let connect_arg = format!("{cp_ip}:{xds_port}");
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
