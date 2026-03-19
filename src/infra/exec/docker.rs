use std::io::Write as _;
use std::path::Path;
use std::time::Duration;

use crate::errors::{CliError, CliErrorKind};

use super::CommandResult;
use super::{k3d, run_command, run_command_streaming};

/// Run docker.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker(args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, CliError> {
    let mut command: Vec<&str> = vec!["docker"];
    command.extend_from_slice(args);
    run_command(&command, None, None, ok_exit_codes)
}

/// Check if a k3d cluster exists.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn cluster_exists(name: &str) -> Result<bool, CliError> {
    let result = k3d(&["cluster", "list", "--no-headers"], &[0])?;
    Ok(result
        .stdout
        .lines()
        .any(|line| line.split_whitespace().next() == Some(name)))
}

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

/// Create a Docker network if it does not already exist.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_network_create(name: &str, subnet: &str) -> Result<(), CliError> {
    // Check if network already exists
    let check = docker(
        &[
            "network",
            "ls",
            "--filter",
            &format!("name=^{name}$"),
            "--format",
            "{{.Name}}",
        ],
        &[0],
    )?;
    if check.stdout.trim() == name {
        return Ok(());
    }
    docker(&["network", "create", "--subnet", subnet, name], &[0])?;
    Ok(())
}

/// Remove a Docker network.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn docker_network_rm(name: &str) -> Result<(), CliError> {
    docker(&["network", "rm", name], &[0, 1])?;
    Ok(())
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

// ---------------------------------------------------------------------------
// Docker Compose (multi-zone universal)
// ---------------------------------------------------------------------------

/// Start services from a compose file with a wait timeout.
///
/// Uses streaming mode so that progress lines (container created, healthy,
/// etc.) are surfaced to the user during long waits.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn compose_up(
    file: &Path,
    project: &str,
    timeout_seconds: u32,
) -> Result<CommandResult, CliError> {
    let file_str = file.to_string_lossy();
    let timeout_str = timeout_seconds.to_string();
    run_command_streaming(
        &[
            "docker",
            "compose",
            "-f",
            &file_str,
            "-p",
            project,
            "up",
            "-d",
            "--wait",
            "--wait-timeout",
            &timeout_str,
        ],
        None,
        None,
        &[0],
    )
}

/// Stop and remove compose services using a compose file.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn compose_down(file: &Path, project: &str) -> Result<CommandResult, CliError> {
    let file_str = file.to_string_lossy();
    run_command(
        &[
            "docker", "compose", "-f", &file_str, "-p", project, "down", "-v",
        ],
        None,
        None,
        &[0],
    )
}

/// Stop and remove compose services by project name only.
///
/// Does not require the original compose file.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn compose_down_project(project: &str) -> Result<CommandResult, CliError> {
    run_command(
        &["docker", "compose", "-p", project, "down", "-v"],
        None,
        None,
        &[0],
    )
}

/// Extract the admin user token from a running CP container.
///
/// The CP stores the admin token in the global-secrets endpoint.
/// Since `localhostIsAdmin` is true by default, we exec into the container
/// using busybox wget to fetch it from localhost.
///
/// # Errors
/// Returns `CliError` if the token cannot be extracted.
pub fn extract_admin_token(cp_container: &str) -> Result<String, CliError> {
    use backoff::ExponentialBackoff;
    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD;

    // The CP bootstraps the admin token asynchronously after startup.
    // Use exponential backoff: starts at 200ms, caps at 2s, gives up after 15s.
    let backoff_config = ExponentialBackoff {
        initial_interval: Duration::from_millis(200),
        max_interval: Duration::from_secs(2),
        max_elapsed_time: Some(Duration::from_secs(15)),
        ..ExponentialBackoff::default()
    };

    backoff::retry(
        backoff_config,
        || -> Result<String, backoff::Error<Box<CliError>>> {
            let result = docker_exec_cmd(
                cp_container,
                &[
                    "/busybox/wget",
                    "-q",
                    "-O",
                    "-",
                    "http://localhost:5681/global-secrets/admin-user-token",
                ],
            )
            .map_err(|e| backoff::Error::transient(Box::new(e)))?;

            let body = serde_json::from_str::<serde_json::Value>(result.stdout.trim()).map_err(
                |error| {
                    backoff::Error::transient(Box::new(CliError::from(CliErrorKind::serialize(
                        format!("invalid JSON in token response: {error}"),
                    ))))
                },
            )?;

            let b64_data = body["data"].as_str().ok_or_else(|| {
                backoff::Error::transient(Box::new(CliError::from(
                    CliErrorKind::token_generation_failed("missing data field"),
                )))
            })?;

            let bytes = STANDARD.decode(b64_data).map_err(|error| {
                backoff::Error::transient(Box::new(CliError::from(
                    CliErrorKind::token_generation_failed(format!("base64 decode failed: {error}")),
                )))
            })?;

            let token = String::from_utf8(bytes).map_err(|error| {
                backoff::Error::permanent(Box::new(CliError::from(
                    CliErrorKind::token_generation_failed(format!(
                        "invalid UTF-8 in token: {error}"
                    )),
                )))
            })?;

            if token.is_empty() {
                return Err(backoff::Error::transient(Box::new(CliError::from(
                    CliErrorKind::token_generation_failed("empty token"),
                ))));
            }

            Ok(token)
        },
    )
    .map_err(|error| {
        CliErrorKind::token_generation_failed(format!(
            "could not extract admin token within timeout: {error}"
        ))
        .into()
    })
}
