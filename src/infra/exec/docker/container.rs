use std::io::Write as _;

use crate::errors::{CliError, CliErrorKind};

use super::super::CommandResult;
use super::command::docker;

/// Start a named Docker container in detached mode. Returns container ID.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_run_detached(
    image: &str,
    name: &str,
    network: &str,
    env: &[(&str, &str)],
    ports: &[(u16, u16)],
    extra_args: &[&str],
    cmd: &[&str],
) -> Result<CommandResult, CliError> {
    let mut args: Vec<&str> = vec!["run", "-d", "--name", name, "--network", network];
    let env_strs: Vec<String> = env.iter().map(|(k, v)| format!("{k}={v}")).collect();
    for e in &env_strs {
        args.push("-e");
        args.push(e);
    }
    let port_strs: Vec<String> = ports.iter().map(|(h, c)| format!("{h}:{c}")).collect();
    for p in &port_strs {
        args.push("-p");
        args.push(p);
    }
    args.extend_from_slice(extra_args);
    args.push(image);
    args.extend_from_slice(cmd);
    docker(&args, &[0])
}

/// Stop and remove a named container.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_rm(name: &str) -> Result<CommandResult, CliError> {
    docker(&["rm", "-f", name], &[0, 1])
}

/// Get the IP address of a container on a given Docker network.
///
/// # Errors
/// Returns `CliError` on command failure or if the IP cannot be extracted.
pub fn docker_inspect_ip(container: &str, network: &str) -> Result<String, CliError> {
    let format_str = format!("{{{{(index .NetworkSettings.Networks \"{network}\").IPAddress}}}}");
    let result = docker(&["inspect", "-f", &format_str, container], &[0])?;
    let ip = result.stdout.trim().to_string();
    if ip.is_empty() {
        return Err(CliErrorKind::container_not_found(container.to_string())
            .with_details(format!("no IP on network {network}")));
    }
    Ok(ip)
}

/// Check if a named container exists and is running.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn container_running(name: &str) -> Result<bool, CliError> {
    let result = docker(&["inspect", "-f", "{{.State.Running}}", name], &[0, 1])?;
    Ok(result.returncode == 0 && result.stdout.trim() == "true")
}

/// Remove all containers matching a label. Returns the list of removed names.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_rm_by_label(label: &str) -> Result<Vec<String>, CliError> {
    let result = docker(
        &[
            "ps",
            "-a",
            "--filter",
            &format!("label={label}"),
            "--format",
            "{{.Names}}",
        ],
        &[0],
    )?;
    let names: Vec<String> = result
        .stdout
        .lines()
        .filter(|l| !l.trim().is_empty())
        .map(|l| l.trim().to_string())
        .collect();
    for name in &names {
        docker_rm(name)?;
    }
    Ok(names)
}

/// Run a command inside a running container.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_exec_cmd(container: &str, cmd: &[&str]) -> Result<CommandResult, CliError> {
    let mut args: Vec<&str> = vec!["exec", container];
    args.extend_from_slice(cmd);
    docker(&args, &[0])
}

/// Run a command inside a running container in detached mode.
///
/// Uses `docker exec -d` so the process runs in the background inside
/// the container without a shell wrapper.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_exec_detached(container: &str, cmd: &[&str]) -> Result<CommandResult, CliError> {
    let mut args: Vec<&str> = vec!["exec", "-d", container];
    args.extend_from_slice(cmd);
    docker(&args, &[0])
}

/// Write `content` to `container_path` inside a running container using `docker cp`.
///
/// Writes to a local temp file then copies it in, avoiding shell interpretation
/// of the content.
///
/// # Errors
/// Returns `CliError` on I/O or `docker cp` failure.
pub fn docker_write_file(
    container: &str,
    container_path: &str,
    content: &str,
) -> Result<(), CliError> {
    let mut tmp =
        tempfile::NamedTempFile::new().map_err(|e| CliErrorKind::io(format!("temp file: {e}")))?;
    tmp.write_all(content.as_bytes())
        .map_err(|e| CliErrorKind::io(format!("write temp file: {e}")))?;
    let src = tmp.path().to_string_lossy();
    let dest = format!("{container}:{container_path}");
    docker(&["cp", &src, &dest], &[0])?;
    Ok(())
}
