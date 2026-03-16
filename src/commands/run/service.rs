use std::time::Duration;

use crate::cli::{RunDirArgs, ServiceArgs};
use crate::cluster::ClusterSpec;
use crate::commands::{resolve_admin_token, resolve_cp_addr, resolve_run_context};
use crate::errors::{CliError, CliErrorKind};
use crate::exec;

use super::token::token_via_api;

// Embed templates at compile time so they ship with the binary.
const TEMPLATE_DATAPLANE: &str =
    include_str!("../../../resources/universal/templates/dataplane.yaml.j2");
const TEMPLATE_TRANSPARENT_PROXY: &str =
    include_str!("../../../resources/universal/templates/transparent-proxy.yaml.j2");

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
            &args.run_dir,
        ),
        "down" => service_down(args.name.as_deref(), &args.run_dir),
        "list" => service_list(&args.run_dir),
        _ => Err(
            CliErrorKind::usage_error(format!("unknown service action: {}", args.action)).into(),
        ),
    }
}

/// Derive a service image name from the CP image by replacing kuma-cp with kuma-universal.
fn derive_service_image(cp_image: &str) -> Option<String> {
    if cp_image.contains("kuma-cp") {
        Some(cp_image.replace("kuma-cp", "kuma-universal"))
    } else {
        None
    }
}

/// Resolve the service image from explicit flag or auto-derive from cluster spec.
fn resolve_service_image(explicit: Option<&str>, spec: &ClusterSpec) -> Result<String, CliError> {
    if let Some(img) = explicit {
        return Ok(img.to_string());
    }
    if let Some(ref cp_img) = spec.cp_image {
        return derive_service_image(cp_img).ok_or_else(|| {
            CliErrorKind::usage_error(format!(
                "cannot derive service image from cp_image '{cp_img}' - pass --image explicitly"
            ))
            .into()
        });
    }
    Err(CliErrorKind::usage_error(
        "service image is required (pass --image or ensure cluster has cp_image set)",
    )
    .into())
}

fn service_up(
    name: Option<&str>,
    image: Option<&str>,
    port: Option<u16>,
    mesh: &str,
    transparent_proxy: bool,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let svc_name = name.ok_or_else(|| CliErrorKind::usage_error("service name is required"))?;
    let svc_port = port.ok_or_else(|| CliErrorKind::usage_error("service port is required"))?;

    let ctx = resolve_run_context(run_dir_args)?;
    let cp_addr = resolve_cp_addr(&ctx)?;
    let admin_token = resolve_admin_token(&ctx)?;
    let spec = ctx
        .cluster
        .as_ref()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("cluster"))?;
    let network = spec
        .docker_network
        .as_deref()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("docker_network"))?;

    let svc_image = resolve_service_image(image, spec)?;

    // Generate token
    let token_result = token_via_api(
        &cp_addr,
        "dataplane",
        svc_name,
        mesh,
        "24h",
        admin_token.as_deref(),
    )?;
    let token_str = token_result.trim();

    // Start service container first so we can inspect its IP address
    let port_pair = [(svc_port, svc_port)];
    exec::docker_run_detached(
        &svc_image,
        svc_name,
        network,
        &[],
        &port_pair,
        &["--label", "io.harness.service=true"],
        &["sleep", "infinity"],
    )?;

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
    let xds_port = spec.primary_member().xds_port.unwrap_or(5678);
    let cp_ip = spec
        .primary_member()
        .container_ip
        .as_deref()
        .ok_or_else(|| CliErrorKind::missing_run_context_value("container_ip"))?;
    let ca_cert = extract_cp_ca_cert(cp_ip, xds_port)?;
    let ca_path = format!("/tmp/{svc_name}-ca.crt");
    exec::docker_write_file(svc_name, &ca_path, &ca_cert)?;

    // Start kuma-dp inside the container.
    // kuma-dp connects to the XDS port (5678), not the API port (5681).
    let xds_addr = format!("https://{cp_ip}:{xds_port}");
    let dp_args = format!(
        "kuma-dp run \
         --cp-address={xds_addr} \
         --dataplane-token-file={token_path} \
         --dataplane-file={dp_path} \
         --ca-cert-file={ca_path} \
         2>&1 &"
    );
    exec::docker_exec_cmd(svc_name, &["sh", "-c", &dp_args])?;

    // Wait for kuma-dp to become ready
    let readiness_url = format!("http://{container_address}:9902/ready");
    eprintln!("service: waiting for {svc_name} readiness at {readiness_url}");
    exec::wait_for_http(&readiness_url, Duration::from_secs(60)).map_err(|_| {
        CliError::from(CliErrorKind::service_readiness_timeout(
            svc_name.to_string(),
        ))
    })?;

    println!("{svc_name}");
    Ok(0)
}

/// Extract the CA certificate from the CP's XDS TLS endpoint.
///
/// Uses `openssl s_client` to connect and extract the PEM certificate.
fn extract_cp_ca_cert(cp_ip: &str, xds_port: u16) -> Result<String, CliError> {
    let connect_arg = format!("{cp_ip}:{xds_port}");
    // echo | openssl s_client -connect host:port -showcerts 2>/dev/null
    let result = exec::run_command(
        &[
            "sh",
            "-c",
            &format!(
                "echo | openssl s_client -connect {connect_arg} -showcerts 2>/dev/null | \
                 sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p'"
            ),
        ],
        None,
        None,
        &[0],
    )?;
    let cert = result.stdout.trim().to_string();
    if cert.is_empty() || !cert.contains("BEGIN CERTIFICATE") {
        return Err(CliErrorKind::cp_api_unreachable(format!(
            "could not extract CA cert from {connect_arg}"
        ))
        .into());
    }
    Ok(cert)
}

fn service_down(name: Option<&str>, _run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let svc_name = name.ok_or_else(|| CliErrorKind::usage_error("service name is required"))?;
    exec::docker_rm(svc_name)?;
    println!("{svc_name} removed");
    Ok(0)
}

fn service_list(_run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
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
