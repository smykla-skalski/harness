use std::fs;
use std::path::{Path, PathBuf};

use crate::cli::{RunDirArgs, ServiceArgs};
use crate::commands::{resolve_admin_token, resolve_cp_addr, resolve_run_context};
use crate::errors::{CliError, CliErrorKind};
use crate::exec;

use super::token::token_via_api;

const TEMPLATE_DIR: &str = "resources/universal/templates";

/// Render a universal mode template from the repo's template directory.
///
/// # Errors
/// Returns `CliError` if the template cannot be found or rendered.
fn render_template(
    repo_root: &Path,
    template_name: &str,
    ctx: &serde_json::Value,
) -> Result<String, CliError> {
    let template_path = repo_root.join(TEMPLATE_DIR).join(template_name);
    let template_str = fs::read_to_string(&template_path)
        .map_err(|_| CliErrorKind::missing_file(template_path.display().to_string()))?;
    let env = minijinja::Environment::new();
    let tmpl = env
        .template_from_str(&template_str)
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

fn service_up(
    name: Option<&str>,
    image: Option<&str>,
    port: Option<u16>,
    mesh: &str,
    transparent_proxy: bool,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let svc_name = name.ok_or_else(|| CliErrorKind::usage_error("service name is required"))?;
    let svc_image = image.ok_or_else(|| {
        CliErrorKind::usage_error(
            "service image is required (should contain kuma-dp, e.g. kuma-universal)",
        )
    })?;
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
        svc_image,
        svc_name,
        network,
        &[],
        &port_pair,
        &["--label", "io.harness.service=true"],
        &["sleep", "infinity"],
    )?;

    // Resolve the container IP on the Docker network
    let container_address = exec::docker_inspect_ip(svc_name, network)?;

    // Render dataplane YAML from template using the resolved address
    let repo_root = PathBuf::from(&ctx.metadata.repo_root);
    let template_name = if transparent_proxy {
        "transparent-proxy.yaml.j2"
    } else {
        "dataplane.yaml.j2"
    };
    let dp_yaml = render_template(
        &repo_root,
        template_name,
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

    // Start kuma-dp inside the container
    let dp_args = format!(
        "kuma-dp run --cp-address={cp_addr} \
         --dataplane-token-file={token_path} \
         --dataplane-file={dp_path}"
    );
    exec::docker_exec_cmd(svc_name, &["sh", "-c", &format!("{dp_args} &")])?;

    println!("{svc_name}");
    Ok(0)
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
