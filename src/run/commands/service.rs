use std::thread;
use std::time::Duration;

use clap::Args;

use tracing::info;

use crate::app::command_context::{CommandContext, Execute, RunDirArgs};
use crate::errors::{CliError, CliErrorKind};
use crate::infra::blocks::kuma::defaults;
use crate::infra::blocks::kuma::service::{KumaService, KumaServiceSpec};
use crate::infra::blocks::{ContainerConfig, ContainerRuntime};
use crate::infra::exec;
use crate::platform::runtime::XdsAccess;

use super::token::token_via_api;

impl Execute for ServiceArgs {
    fn execute(&self, context: &CommandContext) -> Result<i32, CliError> {
        service(context, self)
    }
}

// Embed templates at compile time so they ship with the binary.
const TEMPLATE_DATAPLANE: &str =
    include_str!("../../../resources/universal/templates/dataplane.yaml.j2");
const TEMPLATE_TRANSPARENT_PROXY: &str =
    include_str!("../../../resources/universal/templates/transparent-proxy.yaml.j2");

/// Arguments for `harness run kuma service`.
#[derive(Debug, Clone, Args)]
pub struct ServiceArgs {
    /// Service action.
    #[arg(value_parser = ["up", "down", "list"])]
    pub action: String,
    /// Service name.
    pub name: Option<String>,
    /// Service image.
    #[arg(long)]
    pub image: Option<String>,
    /// Service port.
    #[arg(long)]
    pub port: Option<u16>,
    /// Mesh name.
    #[arg(long, default_value = "default")]
    pub mesh: String,
    /// Enable transparent proxy.
    #[arg(long)]
    pub transparent_proxy: bool,
    /// Readiness timeout in seconds.
    #[arg(long, default_value = "60")]
    pub timeout: u64,
    /// Custom dataplane template path.
    #[arg(long)]
    pub dataplane_template: Option<String>,
    /// Run-directory resolution.
    #[command(flatten)]
    pub run_dir: RunDirArgs,
}

/// Manage universal mode test service containers.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn service(ctx: &CommandContext, args: &ServiceArgs) -> Result<i32, CliError> {
    let docker = ctx
        .blocks()
        .docker
        .as_deref()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("docker"))?;
    match args.action.as_str() {
        "up" => service_up(ctx, args, docker),
        "down" => service_down(args.name.as_deref(), &args.run_dir, docker),
        "list" => service_list(ctx, &args.run_dir, docker),
        _ => Err(
            CliErrorKind::usage_error(format!("unknown service action: {}", args.action)).into(),
        ),
    }
}

fn service_up(
    ctx: &CommandContext,
    args: &ServiceArgs,
    docker: &dyn ContainerRuntime,
) -> Result<i32, CliError> {
    let svc_name = args
        .name
        .as_deref()
        .ok_or_else(|| CliErrorKind::usage_error("service name is required"))?;
    let svc_port = args
        .port
        .ok_or_else(|| CliErrorKind::usage_error("service port is required"))?;

    let services = ctx.resolve_run_services(&args.run_dir)?;
    let access = services.control_plane_access()?;
    let network = services.docker_network()?;
    let svc_image = services.service_image(args.image.as_deref())?;

    // Generate token
    let token_result = token_via_api(
        access.addr.as_ref(),
        "dataplane",
        svc_name,
        &args.mesh,
        defaults::DEFAULT_TOKEN_VALID_FOR,
        access.admin_token,
    )?;
    let token_str = token_result.trim();

    // Start service container first so we can inspect its IP address
    docker.run_detached(&ContainerConfig {
        image: svc_image.into_owned(),
        name: svc_name.to_string(),
        network: network.to_string(),
        env: vec![],
        ports: vec![(svc_port, svc_port)],
        labels: vec![
            ("io.harness.service".to_string(), "true".to_string()),
            (
                "io.harness.run-id".to_string(),
                services.layout().run_id.clone(),
            ),
        ],
        extra_args: vec![],
        command: vec!["sleep".to_string(), "infinity".to_string()],
    })?;

    // Run the rest inside a helper; on failure clean up the container
    if let Err(err) = service_up_inner(&ServiceSetup {
        docker,
        name: svc_name,
        port: svc_port,
        mesh: &args.mesh,
        network,
        token: token_str,
        transparent_proxy: args.transparent_proxy,
        timeout: args.timeout,
        xds: services.xds_access()?,
    }) {
        let _ = docker.remove(svc_name);
        return Err(err);
    }

    println!("{svc_name}");
    Ok(0)
}

/// Arguments for the post-container-start setup phase.
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

/// Post-container-start setup: configure dataplane, inject certs, wait for readiness.
fn service_up_inner(setup: &ServiceSetup<'_>) -> Result<(), CliError> {
    let svc_name = setup.name;
    let svc_port = setup.port;
    let mesh = setup.mesh;
    let token_str = setup.token;
    let network = setup.network;
    let transparent_proxy = setup.transparent_proxy;
    // Resolve the container IP on the Docker network
    let container_address = setup.docker.inspect_ip(svc_name, network)?;
    let files = KumaService::files_for(svc_name);

    // Render dataplane YAML from embedded template using the resolved address
    let (template_name, template_content) = if transparent_proxy {
        ("transparent-proxy.yaml.j2", TEMPLATE_TRANSPARENT_PROXY)
    } else {
        ("dataplane.yaml.j2", TEMPLATE_DATAPLANE)
    };
    let dp_yaml = KumaService::render_dataplane_template(
        template_name,
        template_content,
        &KumaServiceSpec {
            name: svc_name.to_string(),
            mesh: mesh.to_string(),
            address: container_address.clone(),
            port: svc_port,
            transparent_proxy,
        },
    )
    .map_err(|error| CliErrorKind::template_render(error.to_string()))?;

    // Write token and dataplane YAML into container while extracting CA cert in parallel.
    let ca_cert = thread::scope(|scope| {
        let t_token = scope.spawn(|| {
            setup
                .docker
                .write_file(svc_name, &files.token_path, token_str)
        });
        let t_yaml = scope.spawn(|| {
            setup
                .docker
                .write_file(svc_name, &files.dataplane_path, &dp_yaml)
        });
        let t_cert = scope.spawn(|| extract_cp_ca_cert(setup.xds.ip, setup.xds.port));
        t_token.join().expect("token write thread panicked")?;
        t_yaml.join().expect("yaml write thread panicked")?;
        t_cert.join().expect("cert extract thread panicked")
    })?;

    // Install transparent proxy if requested
    if transparent_proxy {
        setup.docker.exec_command(
            svc_name,
            &["kumactl", "install", "transparent-proxy", "--redirect-dns"],
        )?;
    }

    // Inject the CA cert into the container.
    // kuma-dp needs this to verify the TLS connection to the CP.
    setup
        .docker
        .write_file(svc_name, &files.ca_cert_path, &ca_cert)?;

    // Start kuma-dp inside the container in detached mode.
    // kuma-dp connects to the XDS port (5678), not the API port (5681).
    let launch = KumaService::launch_for(svc_name, &files, setup.xds);
    let launch_args = launch.args.iter().map(String::as_str).collect::<Vec<_>>();
    setup.docker.exec_detached(svc_name, &launch_args)?;

    // Wait for kuma-dp to become ready
    let readiness_url = KumaService::readiness_url(&container_address);
    info!(%svc_name, %readiness_url, "waiting for service readiness");
    exec::wait_for_http(&readiness_url, Duration::from_secs(setup.timeout)).map_err(|_| {
        CliError::from(CliErrorKind::service_readiness_timeout(
            svc_name.to_string(),
        ))
    })?;

    Ok(())
}

/// Extract the CA certificate from the CP's XDS TLS endpoint.
///
/// Runs `openssl s_client` to fetch TLS certificates, then extracts PEM
/// blocks with Rust string operations instead of piping through sed.
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
    // Extract PEM certificate blocks from the openssl output
    let cert = extract_pem_certificates(&result.stdout);
    if cert.is_empty() {
        return Err(CliErrorKind::cp_api_unreachable(format!(
            "could not extract CA cert from {connect_arg}"
        ))
        .into());
    }
    Ok(cert)
}

/// Extract all PEM certificate blocks from raw openssl output.
fn extract_pem_certificates(output: &str) -> String {
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

fn service_down(
    name: Option<&str>,
    _run_dir_args: &RunDirArgs,
    docker: &dyn ContainerRuntime,
) -> Result<i32, CliError> {
    let svc_name = name.ok_or_else(|| CliErrorKind::usage_error("service name is required"))?;
    docker.remove(svc_name)?;
    println!("{svc_name} removed");
    Ok(0)
}

fn service_list(
    ctx: &CommandContext,
    run_dir_args: &RunDirArgs,
    docker: &dyn ContainerRuntime,
) -> Result<i32, CliError> {
    if let Ok(services) = ctx.resolve_run_services(run_dir_args) {
        for row in services.list_service_containers()? {
            println!("{}\t{}", row.name, row.status);
        }
        return Ok(0);
    }

    let result = docker.list_formatted(
        &["--filter", "label=io.harness.service=true"],
        "{{.Names}}\t{{.Status}}",
    )?;
    print!("{}", result.stdout);
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::platform::cluster::{ClusterSpec, Platform};
    use crate::platform::runtime::ClusterRuntime;

    // -- runtime service image tests --

    #[test]
    fn resolve_image_explicit_wins() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        let runtime = ClusterRuntime::from_spec(&spec);
        let result = runtime.service_image(Some("my-image:v1")).unwrap();
        assert_eq!(result, "my-image:v1");
    }

    #[test]
    fn resolve_image_derives_from_cp_image() {
        let mut spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        spec.cp_image = Some("kuma-cp:dev".into());
        let runtime = ClusterRuntime::from_spec(&spec);
        let result = runtime.service_image(None).unwrap();
        assert_eq!(result, "kuma-universal:dev");
    }

    #[test]
    fn extract_pem_certificates_finds_certs() {
        let raw = "CONNECTED\n\
            depth=0 CN=kuma-cp\n\
            ---\n\
            -----BEGIN CERTIFICATE-----\n\
            MIIB1234==\n\
            -----END CERTIFICATE-----\n\
            ---\n\
            other noise\n";
        let cert = extract_pem_certificates(raw);
        assert!(cert.contains("BEGIN CERTIFICATE"));
        assert!(cert.contains("MIIB1234=="));
        assert!(!cert.contains("CONNECTED"));
    }

    #[test]
    fn extract_pem_certificates_empty_on_no_cert() {
        let raw = "CONNECTED\nno cert here\n";
        assert!(extract_pem_certificates(raw).is_empty());
    }

    #[test]
    fn resolve_image_errors_when_no_cp_image() {
        let spec = ClusterSpec::from_mode_with_platform(
            "single-up",
            &["cp".into()],
            "/r",
            vec![],
            vec![],
            Platform::Universal,
        )
        .unwrap();
        let runtime = ClusterRuntime::from_spec(&spec);
        let result = runtime.service_image(None);
        assert!(result.is_err());
    }
}
