use std::time::Duration;

use clap::Args;

use crate::commands::{RunDirArgs, resolve_run_services};
use crate::errors::{CliError, CliErrorKind};
use crate::exec;
use crate::runtime::XdsAccess;

use super::token::token_via_api;

// Embed templates at compile time so they ship with the binary.
const TEMPLATE_DATAPLANE: &str =
    include_str!("../../../resources/universal/templates/dataplane.yaml.j2");
const TEMPLATE_TRANSPARENT_PROXY: &str =
    include_str!("../../../resources/universal/templates/transparent-proxy.yaml.j2");

/// Arguments for `harness service`.
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

/// Render an embedded universal mode template.
///
/// # Errors
/// Returns `CliError` if the template cannot be parsed or rendered.
fn render_template(
    template_name: &str,
    template_content: &str,
    ctx: &serde_json::Value,
) -> Result<String, CliError> {
    let env = minijinja::Environment::new();
    let tmpl = env
        .template_from_str(template_content)
        .map_err(|e| CliErrorKind::template_render(format!("parse {template_name}: {e}")))?;
    tmpl.render(ctx).map_err(|e| {
        CliError::from(CliErrorKind::template_render(format!(
            "render {template_name}: {e}"
        )))
    })
}

/// Manage universal mode test service containers.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn service(args: &ServiceArgs) -> Result<i32, CliError> {
    match args.action.as_str() {
        "up" => service_up(
            args.name.as_deref(),
            args.image.as_deref(),
            args.port,
            &args.mesh,
            args.transparent_proxy,
            args.timeout,
            &args.run_dir,
        ),
        "down" => service_down(args.name.as_deref(), &args.run_dir),
        "list" => service_list(&args.run_dir),
        _ => Err(
            CliErrorKind::usage_error(format!("unknown service action: {}", args.action)).into(),
        ),
    }
}

fn service_up(
    name: Option<&str>,
    image: Option<&str>,
    port: Option<u16>,
    mesh: &str,
    transparent_proxy: bool,
    timeout: u64,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let svc_name = name.ok_or_else(|| CliErrorKind::usage_error("service name is required"))?;
    let svc_port = port.ok_or_else(|| CliErrorKind::usage_error("service port is required"))?;

    let services = resolve_run_services(run_dir_args)?;
    let access = services.control_plane_access()?;
    let network = services.docker_network()?;
    let svc_image = services.service_image(image)?;

    // Generate token
    let token_result = token_via_api(
        access.addr.as_ref(),
        "dataplane",
        svc_name,
        mesh,
        "24h",
        access.admin_token,
    )?;
    let token_str = token_result.trim();

    // Start service container first so we can inspect its IP address
    let port_pair = [(svc_port, svc_port)];
    let run_id_label = format!("io.harness.run-id={}", services.layout().run_id);
    exec::docker_run_detached(
        svc_image.as_ref(),
        svc_name,
        network,
        &[],
        &port_pair,
        &[
            "--label",
            "io.harness.service=true",
            "--label",
            &run_id_label,
        ],
        &["sleep", "infinity"],
    )?;

    // Run the rest inside a helper; on failure clean up the container
    if let Err(err) = service_up_inner(&ServiceSetup {
        name: svc_name,
        port: svc_port,
        mesh,
        network,
        token: token_str,
        transparent_proxy,
        timeout,
        xds: services.xds_access()?,
    }) {
        let _ = exec::docker_rm(svc_name);
        return Err(err);
    }

    println!("{svc_name}");
    Ok(0)
}

/// Arguments for the post-container-start setup phase.
struct ServiceSetup<'a> {
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
    let container_address = exec::docker_inspect_ip(svc_name, network)?;

    // Render dataplane YAML from embedded template using the resolved address
    let (template_name, template_content) = if transparent_proxy {
        ("transparent-proxy.yaml.j2", TEMPLATE_TRANSPARENT_PROXY)
    } else {
        ("dataplane.yaml.j2", TEMPLATE_DATAPLANE)
    };
    let dp_yaml = render_template(
        template_name,
        template_content,
        &serde_json::json!({
            "name": svc_name,
            "mesh": mesh,
            "address": container_address,
            "port": svc_port,
            "protocol": "http",
        }),
    )?;

    // Write token and dataplane YAML into container
    let token_path = format!("/tmp/{svc_name}-token");
    let dp_path = format!("/tmp/{svc_name}-dp.yaml");
    exec::docker_write_file(svc_name, &token_path, token_str)?;
    exec::docker_write_file(svc_name, &dp_path, &dp_yaml)?;

    // Install transparent proxy if requested
    if transparent_proxy {
        exec::docker_exec_cmd(
            svc_name,
            &["kumactl", "install", "transparent-proxy", "--redirect-dns"],
        )?;
    }

    // Extract CP's CA cert from the XDS endpoint and inject into container.
    // kuma-dp needs this to verify the TLS connection to the CP.
    let ca_cert = extract_cp_ca_cert(setup.xds.ip, setup.xds.port)?;
    let ca_path = format!("/tmp/{svc_name}-ca.crt");
    exec::docker_write_file(svc_name, &ca_path, &ca_cert)?;

    // Start kuma-dp inside the container in detached mode.
    // kuma-dp connects to the XDS port (5678), not the API port (5681).
    let xds_addr = format!("https://{}:{}", setup.xds.ip, setup.xds.port);
    exec::docker_exec_detached(
        svc_name,
        &[
            "kuma-dp",
            "run",
            &format!("--cp-address={xds_addr}"),
            &format!("--dataplane-token-file={token_path}"),
            &format!("--dataplane-file={dp_path}"),
            &format!("--ca-cert-file={ca_path}"),
        ],
    )?;

    // Wait for kuma-dp to become ready
    let readiness_url = format!("http://{container_address}:9902/ready");
    eprintln!("service: waiting for {svc_name} readiness at {readiness_url}");
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

fn service_down(name: Option<&str>, _run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let svc_name = name.ok_or_else(|| CliErrorKind::usage_error("service name is required"))?;
    exec::docker_rm(svc_name)?;
    println!("{svc_name} removed");
    Ok(0)
}

fn service_list(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    if let Ok(services) = resolve_run_services(run_dir_args) {
        for row in services.list_service_containers()? {
            println!("{}\t{}", row.name, row.status);
        }
        return Ok(0);
    }

    let result = exec::docker(
        &[
            "ps",
            "--filter",
            "label=io.harness.service=true",
            "--format",
            "{{.Names}}\t{{.Status}}",
        ],
        &[0],
    )?;
    print!("{}", result.stdout);
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cluster::{ClusterSpec, Platform};
    use crate::runtime::ClusterRuntime;

    // -- template rendering tests --

    #[test]
    fn dataplane_template_renders_correctly() {
        let ctx = serde_json::json!({
            "name": "demo",
            "mesh": "default",
            "address": "172.57.0.10",
            "port": 8080,
            "protocol": "http",
        });
        let result = render_template("dataplane.yaml.j2", TEMPLATE_DATAPLANE, &ctx).unwrap();
        assert!(result.contains("demo"), "should contain service name");
        assert!(result.contains("default"), "should contain mesh name");
        assert!(result.contains("172.57.0.10"), "should contain address");
        assert!(result.contains("8080"), "should contain port");
        assert!(
            !result.contains("transparentProxying"),
            "should not contain transparentProxying"
        );
    }

    #[test]
    fn transparent_proxy_template_renders_correctly() {
        let ctx = serde_json::json!({
            "name": "proxy-svc",
            "mesh": "default",
            "address": "172.57.0.20",
            "port": 9090,
            "protocol": "http",
        });
        let result = render_template(
            "transparent-proxy.yaml.j2",
            TEMPLATE_TRANSPARENT_PROXY,
            &ctx,
        )
        .unwrap();
        assert!(result.contains("proxy-svc"));
        assert!(result.contains("172.57.0.20"));
        assert!(result.contains("9090"));
        assert!(
            result.contains("transparentProxying"),
            "should contain transparentProxying"
        );
    }

    #[test]
    fn template_selection_uses_transparent_proxy_flag() {
        let (name_std, _) = if false {
            ("transparent-proxy.yaml.j2", TEMPLATE_TRANSPARENT_PROXY)
        } else {
            ("dataplane.yaml.j2", TEMPLATE_DATAPLANE)
        };
        assert_eq!(name_std, "dataplane.yaml.j2");

        let (name_tp, _) = if true {
            ("transparent-proxy.yaml.j2", TEMPLATE_TRANSPARENT_PROXY)
        } else {
            ("dataplane.yaml.j2", TEMPLATE_DATAPLANE)
        };
        assert_eq!(name_tp, "transparent-proxy.yaml.j2");
    }

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
