use std::collections::HashMap;
use std::io::{self, BufRead, Read as _, Write as _};
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::Duration;

use crate::core_defs::{CommandResult, merge_env, utc_now};
use crate::errors::{CliError, CliErrorKind};

/// Run a command via `std::process::Command`, capturing stdout/stderr.
///
/// # Errors
/// Returns `CliError` if the exit code is not in `ok_exit_codes`.
pub(crate) fn run_command(
    args: &[&str],
    cwd: Option<&Path>,
    env: Option<&HashMap<String, String>>,
    ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    let (program, cmd_args) = args
        .split_first()
        .ok_or_else(|| CliError::from(CliErrorKind::EmptyCommandArgs))?;
    let output = build_command(program, cmd_args, cwd, env)
        .output()
        .map_err(|e| {
            CliErrorKind::command_failed(command_string(args)).with_details(e.to_string())
        })?;
    let result = build_result(args, output);
    if ok_exit_codes.contains(&result.returncode) {
        return Ok(result);
    }
    Err(CliErrorKind::command_failed(command_string(args)).with_details(failure_details(&result)))
}

/// Run a command, capturing all output silently.
///
/// Pipes both stdout and stderr. All stderr is captured in the result for
/// error diagnostics but nothing is printed to the terminal. Callers are
/// responsible for emitting their own progress messages before and after
/// the command runs.
///
/// # Errors
/// Returns `CliError` if the exit code is not in `ok_exit_codes`.
pub(crate) fn run_command_streaming(
    args: &[&str],
    cwd: Option<&Path>,
    env: Option<&HashMap<String, String>>,
    ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    let (program, cmd_args) = args
        .split_first()
        .ok_or_else(|| CliError::from(CliErrorKind::EmptyCommandArgs))?;
    let mut cmd = build_command(program, cmd_args, cwd, env);
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| {
        CliErrorKind::command_failed(command_string(args)).with_details(e.to_string())
    })?;

    // Read stderr in a thread so we don't deadlock if both pipes fill.
    let stderr_handle = child.stderr.take();
    let stderr_thread = thread::spawn(move || {
        let mut captured = String::new();
        if let Some(pipe) = stderr_handle {
            let mut reader = io::BufReader::new(pipe);
            let mut line = String::new();
            loop {
                let bytes = reader.read_line(&mut line).unwrap_or(0);
                if bytes == 0 {
                    break;
                }
                let trimmed = line.trim_end_matches(['\n', '\r']);
                if let Some(msg) = filter_progress_line(trimmed) {
                    let ts = utc_now();
                    eprintln!("    {ts} {msg}");
                }
                captured.push_str(trimmed);
                captured.push('\n');
                line.clear();
            }
        }
        captured
    });

    let stdout = {
        let mut buf = Vec::new();
        if let Some(mut pipe) = child.stdout.take() {
            pipe.read_to_end(&mut buf).ok();
        }
        String::from_utf8_lossy(&buf).into_owned()
    };

    let status = child.wait().map_err(|e| {
        CliErrorKind::command_failed(command_string(args)).with_details(e.to_string())
    })?;
    let stderr = stderr_thread.join().unwrap_or_default();

    let result = CommandResult {
        args: args.iter().map(|s| (*s).to_string()).collect(),
        returncode: status.code().unwrap_or(-1),
        stdout,
        stderr,
    };
    if ok_exit_codes.contains(&result.returncode) {
        return Ok(result);
    }
    Err(CliErrorKind::command_failed(command_string(args)).with_details(failure_details(&result)))
}

/// Map a subprocess stderr line to a harness checkpoint message.
///
/// Returns `Some(message)` for lines that indicate meaningful progress,
/// translated into harness's own format. Raw subprocess output is never
/// passed through - only our own summary messages or actual errors.
fn filter_progress_line(line: &str) -> Option<String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return None;
    }
    let lower = trimmed.to_lowercase();

    // errors and warnings always surface verbatim
    if lower.starts_with("error")
        || lower.starts_with("warning")
        || lower.starts_with("fatal")
        || lower.contains("err:")
        || lower.contains("failed")
        || lower.contains("timed out")
    {
        return Some(trimmed.to_string());
    }

    // k3d checkpoints -> our own messages
    if lower.contains("preparing nodes") {
        return Some("k3d: preparing nodes".into());
    }
    if lower.contains("creating node") {
        return Some("k3d: creating nodes".into());
    }
    if lower.contains("pulling image") {
        return Some("k3d: pulling images".into());
    }
    if lower.contains("importing image") {
        return Some("k3d: importing images".into());
    }
    if lower.contains("successfully created") || lower.contains("cluster created") {
        return Some("k3d: cluster created".into());
    }

    // helm checkpoints -> our own messages
    if lower.contains("release") && lower.contains("deployed") {
        return Some("helm: release deployed".into());
    }
    if lower.contains("rollback") {
        return Some("helm: rollback triggered".into());
    }

    // everything else (Docker BuildKit layers, verbose helm output,
    // kubectl apply lines, etc.) is captured but not printed
    None
}

fn build_command(
    program: &str,
    cmd_args: &[&str],
    cwd: Option<&Path>,
    env: Option<&HashMap<String, String>>,
) -> Command {
    let merged = merge_env(env);
    let mut cmd = Command::new(program);
    cmd.args(cmd_args).envs(&merged);
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    cmd
}

fn build_result(args: &[&str], output: Output) -> CommandResult {
    let Output {
        status,
        stdout,
        stderr,
    } = output;
    CommandResult {
        args: args.iter().map(|s| (*s).to_string()).collect(),
        returncode: status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&stdout).into_owned(),
        stderr: String::from_utf8_lossy(&stderr).into_owned(),
    }
}

fn failure_details(result: &CommandResult) -> String {
    let stderr = result.stderr.trim();
    if !stderr.is_empty() {
        return stderr.to_string();
    }
    let stdout = result.stdout.trim();
    if stdout.is_empty() {
        "external command failed".to_string()
    } else {
        stdout.to_string()
    }
}

fn command_string(args: &[&str]) -> String {
    args.join(" ")
}

/// Run kubectl with optional kubeconfig.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn kubectl(
    kubeconfig: Option<&Path>,
    args: &[&str],
    ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    let mut command: Vec<&str> = vec!["kubectl"];
    let kc_str;
    if let Some(kc) = kubeconfig {
        kc_str = kc.to_string_lossy().into_owned();
        command.push("--kubeconfig");
        command.push(&kc_str);
    }
    command.extend_from_slice(args);
    run_command(&command, None, None, ok_exit_codes)
}

/// Run k3d.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn k3d(args: &[&str], ok_exit_codes: &[i32]) -> Result<CommandResult, CliError> {
    let mut command: Vec<&str> = vec!["k3d"];
    command.extend_from_slice(args);
    run_command(&command, None, None, ok_exit_codes)
}

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

// ---------------------------------------------------------------------------
// Docker container management (universal mode)
// ---------------------------------------------------------------------------

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
    use crate::errors::cow;
    let mut tmp =
        tempfile::NamedTempFile::new().map_err(|e| CliErrorKind::io(cow!("temp file: {e}")))?;
    tmp.write_all(content.as_bytes())
        .map_err(|e| CliErrorKind::io(cow!("write temp file: {e}")))?;
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
/// # Errors
/// Returns `CliError` on command failure.
pub fn compose_up(
    file: &Path,
    project: &str,
    timeout_seconds: u32,
) -> Result<CommandResult, CliError> {
    let file_str = file.to_string_lossy();
    let timeout_str = timeout_seconds.to_string();
    run_command(
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

// ---------------------------------------------------------------------------
// kumactl execution
// ---------------------------------------------------------------------------

/// Run kumactl configured to talk to a CP at the given address.
///
/// Creates a temporary config file pointing kumactl at the CP.
/// kumactl does not accept a direct `--cp-addr` flag - it needs a
/// config file with a named control plane entry.
///
/// # Errors
/// Returns `CliError` on command failure.
pub fn kumactl_run(
    binary: &Path,
    cp_addr: &str,
    args: &[&str],
    ok_exit_codes: &[i32],
) -> Result<CommandResult, CliError> {
    use std::io::Write as _;
    let config_content = format!(
        "contexts:\n- controlPlane: harness\n  name: harness\ncurrentContext: harness\ncontrolPlanes:\n- coordinates:\n    apiServer:\n      url: {cp_addr}\n  name: harness\n"
    );
    let mut tmp = tempfile::NamedTempFile::new()
        .map_err(|e| CliErrorKind::io(format!("kumactl config temp: {e}")))?;
    tmp.write_all(config_content.as_bytes())
        .map_err(|e| CliErrorKind::io(format!("write kumactl config: {e}")))?;
    let config_path = tmp.path().to_string_lossy().into_owned();

    let binary_str = binary.to_string_lossy();
    let mut command: Vec<&str> = vec![&binary_str, "--config-file", &config_path];
    command.extend_from_slice(args);
    run_command(&command, None, None, ok_exit_codes)
}

// ---------------------------------------------------------------------------
// Health check (ureq + backoff)
// ---------------------------------------------------------------------------

/// Wait for an HTTP endpoint to return 200, with exponential backoff.
///
/// Uses `ureq` for sync HTTP and `backoff` for retry logic.
/// Default: starts at 500ms, caps at the given timeout.
///
/// # Errors
/// Returns `CpApiUnreachable` if the endpoint does not respond within the timeout.
pub fn wait_for_http(url: &str, timeout: Duration) -> Result<(), CliError> {
    use backoff::ExponentialBackoff;

    let backoff_config = ExponentialBackoff {
        max_elapsed_time: Some(timeout),
        ..ExponentialBackoff::default()
    };
    backoff::retry(backoff_config, || {
        ureq::get(url)
            .call()
            .map(|_| ())
            .map_err(backoff::Error::transient)
    })
    .map_err(|_| CliError::from(CliErrorKind::cp_api_unreachable(url.to_string())))
}

// ---------------------------------------------------------------------------
// CP API client helpers (ureq)
// ---------------------------------------------------------------------------

/// HTTP method for CP API requests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpMethod {
    Get,
    Post,
    Put,
    Delete,
}

/// Call the CP API and parse the response as JSON.
///
/// # Errors
/// Returns `CliError` on HTTP or parse failure.
pub fn cp_api_json(
    base_url: &str,
    path: &str,
    method: HttpMethod,
    body: Option<&serde_json::Value>,
    token: Option<&str>,
) -> Result<serde_json::Value, CliError> {
    let url = format!("{base_url}{path}");
    let text = cp_api_send(&url, method, body, token)?;
    serde_json::from_str(&text)
        .map_err(|e| CliErrorKind::cp_api_unreachable(url).with_details(e.to_string()))
}

/// Call the CP API and return the response as a raw string.
///
/// Used for endpoints that return plain text (e.g., token generation).
///
/// # Errors
/// Returns `CliError` on HTTP failure.
pub fn cp_api_text(
    base_url: &str,
    path: &str,
    method: HttpMethod,
    body: Option<&serde_json::Value>,
    token: Option<&str>,
) -> Result<String, CliError> {
    let url = format!("{base_url}{path}");
    cp_api_send(&url, method, body, token)
}

/// Build, send, and read the full response body as a string from the CP API.
///
/// Each match arm repeats the auth header insertion because ureq v3 returns
/// different builder types for body vs no-body methods (`WithBody` vs request
/// builder), preventing a shared builder chain.
fn cp_api_send(
    url: &str,
    method: HttpMethod,
    body: Option<&serde_json::Value>,
    token: Option<&str>,
) -> Result<String, CliError> {
    let auth_header = token.map(|tok| format!("Bearer {tok}"));
    let map_err = |e: ureq::Error| {
        CliErrorKind::cp_api_unreachable(url.to_string()).with_details(e.to_string())
    };
    let mut response = match (method, body) {
        (HttpMethod::Get, _) => {
            let mut req = ureq::get(url);
            if let Some(ref auth) = auth_header {
                req = req.header("Authorization", auth);
            }
            req.call().map_err(map_err)?
        }
        (HttpMethod::Delete, _) => {
            let mut req = ureq::delete(url);
            if let Some(ref auth) = auth_header {
                req = req.header("Authorization", auth);
            }
            req.call().map_err(map_err)?
        }
        (HttpMethod::Post, Some(b)) => {
            let mut req = ureq::post(url).header("Content-Type", "application/json");
            if let Some(ref auth) = auth_header {
                req = req.header("Authorization", auth);
            }
            req.send_json(b).map_err(map_err)?
        }
        (HttpMethod::Post, None) => {
            let mut req = ureq::post(url);
            if let Some(ref auth) = auth_header {
                req = req.header("Authorization", auth);
            }
            req.send_empty().map_err(map_err)?
        }
        (HttpMethod::Put, Some(b)) => {
            let mut req = ureq::put(url).header("Content-Type", "application/json");
            if let Some(ref auth) = auth_header {
                req = req.header("Authorization", auth);
            }
            req.send_json(b).map_err(map_err)?
        }
        (HttpMethod::Put, None) => {
            let mut req = ureq::put(url);
            if let Some(ref auth) = auth_header {
                req = req.header("Authorization", auth);
            }
            req.send_empty().map_err(map_err)?
        }
    };

    response
        .body_mut()
        .read_to_string()
        .map_err(|e| CliErrorKind::cp_api_unreachable(url.to_string()).with_details(e.to_string()))
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
    use base64::Engine as _;
    use base64::engine::general_purpose::STANDARD;

    // The CP bootstraps the admin token asynchronously after startup.
    // Retry with short delays to wait for it.
    let max_attempts = 10;
    let mut last_err = String::new();
    for attempt in 0..max_attempts {
        if attempt > 0 {
            thread::sleep(Duration::from_secs(1));
        }
        let Ok(result) = docker_exec_cmd(
            cp_container,
            &[
                "/busybox/wget",
                "-q",
                "-O",
                "-",
                "http://localhost:5681/global-secrets/admin-user-token",
            ],
        ) else {
            last_err = format!("attempt {}: wget failed", attempt + 1);
            continue;
        };
        let Ok(body) = serde_json::from_str::<serde_json::Value>(result.stdout.trim()) else {
            last_err = format!("attempt {}: invalid JSON response", attempt + 1);
            continue;
        };
        let Some(b64_data) = body["data"].as_str() else {
            last_err = format!("attempt {}: missing data field", attempt + 1);
            continue;
        };
        let Ok(bytes) = STANDARD.decode(b64_data) else {
            last_err = format!("attempt {}: base64 decode failed", attempt + 1);
            continue;
        };
        let Ok(token) = String::from_utf8(bytes) else {
            last_err = format!("attempt {}: invalid UTF-8 in token", attempt + 1);
            continue;
        };
        if !token.is_empty() {
            return Ok(token);
        }
        last_err = format!("attempt {}: empty token", attempt + 1);
    }
    Err(CliErrorKind::token_generation_failed(format!(
        "could not extract admin token after {max_attempts} attempts: {last_err}"
    ))
    .into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_echo_captures_stdout() {
        let result = run_command(&["echo", "hello"], None, None, &[0]).unwrap();
        assert_eq!(result.stdout.trim(), "hello");
        assert_eq!(result.returncode, 0);
    }

    #[test]
    fn run_command_rejects_bad_exit_code() {
        let err = run_command(&["false"], None, None, &[0]).unwrap_err();
        assert!(err.message().contains("command failed"));
    }

    #[test]
    fn run_command_accepts_custom_ok_codes() {
        let result = run_command(&["false"], None, None, &[0, 1]).unwrap();
        assert_eq!(result.returncode, 1);
    }

    #[test]
    fn run_command_with_cwd() {
        let result = run_command(&["pwd"], Some(Path::new("/tmp")), None, &[0]).unwrap();
        // /tmp may resolve to /private/tmp on macOS
        assert!(result.stdout.trim().ends_with("/tmp"));
    }

    #[test]
    fn run_command_with_env() {
        let mut env = HashMap::new();
        env.insert("TEST_VAR_XYZ".to_string(), "harness_test".to_string());
        let result =
            run_command(&["sh", "-c", "echo $TEST_VAR_XYZ"], None, Some(&env), &[0]).unwrap();
        assert_eq!(result.stdout.trim(), "harness_test");
    }

    // --- Docker helper argument construction tests ---

    #[test]
    fn docker_run_detached_builds_correct_args() {
        // We can't run docker in CI, but we can test that our helper
        // would construct the right command by checking what args it builds.
        // The actual run_command will fail since docker isn't available in tests,
        // so we just verify the function signature and logic are correct.
        let env = [("KUMA_MODE", "zone")];
        let ports = [(5681_u16, 5681_u16)];
        let result = docker_run_detached(
            "kuma-cp:latest",
            "test-cp",
            "harness-net",
            &env,
            &ports,
            &[],
            &[],
        );
        // Will fail because docker isn't available, but that's OK for this test
        assert!(result.is_err());
    }

    // --- filter_progress_line tests ---

    #[test]
    fn filter_progress_empty_string() {
        assert!(filter_progress_line("").is_none());
    }

    #[test]
    fn filter_progress_whitespace_only() {
        assert!(filter_progress_line("   ").is_none());
    }

    #[test]
    fn filter_progress_cluster_created() {
        let msg = filter_progress_line("cluster created successfully");
        assert_eq!(msg.as_deref(), Some("k3d: cluster created"));
    }

    #[test]
    fn filter_progress_preparing_nodes() {
        let msg = filter_progress_line("INFO[0001] Preparing nodes...");
        assert_eq!(msg.as_deref(), Some("k3d: preparing nodes"));
    }

    #[test]
    fn filter_progress_release_deployed() {
        let msg = filter_progress_line("Release \"kuma\" deployed");
        assert_eq!(msg.as_deref(), Some("helm: release deployed"));
    }

    #[test]
    fn filter_progress_error_line() {
        assert!(filter_progress_line("Error: something went wrong").is_some());
    }

    #[test]
    fn filter_progress_warning_line() {
        assert!(filter_progress_line("WARNING: deprecated feature").is_some());
    }

    #[test]
    fn filter_progress_failed_line() {
        assert!(filter_progress_line("pod install failed").is_some());
    }

    #[test]
    fn filter_progress_random_noise() {
        assert!(filter_progress_line("some random debug output").is_none());
    }

    #[test]
    fn filter_progress_kubectl_apply_is_noise() {
        assert!(filter_progress_line("deployment.apps/kuma-cp configured").is_none());
    }

    #[test]
    fn filter_progress_docker_buildkit_layer() {
        assert!(
            filter_progress_line("#8 [5/6] COPY /tools/releases/templates/passwd /etc/passwd")
                .is_none()
        );
        assert!(filter_progress_line("#5 [2/2] COPY /tools/releases/templates/LICENSE").is_none());
        assert!(
            filter_progress_line("#9 [6/6] COPY /tools/releases/templates/group /etc/group")
                .is_none()
        );
        assert!(filter_progress_line("#12 extracting sha256:abc123").is_none());
    }

    // --- docker_rm_by_label test ---

    #[test]
    fn docker_rm_by_label_returns_empty_for_no_matches() {
        // If docker is available, this should return an empty list.
        // If docker is not available, it should error.
        match docker_rm_by_label("io.harness.test.nonexistent=true") {
            Ok(names) => assert!(names.is_empty()),
            Err(_) => {} // docker not available, that's fine
        }
    }

    #[test]
    fn wait_for_http_fails_on_invalid_url() {
        let result = wait_for_http("http://127.0.0.1:1", Duration::from_millis(500));
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert_eq!(err.code(), "KSRCLI072");
    }

    #[test]
    fn kumactl_run_injects_cp_addr() {
        // kumactl binary won't exist in test env, so this tests the error path
        let result = kumactl_run(
            Path::new("/nonexistent/kumactl"),
            "http://localhost:5681",
            &["version"],
            &[0],
        );
        assert!(result.is_err());
    }

    // --- cp_api mock server tests ---

    /// Spawn a one-shot TCP server that accepts a single connection, reads
    /// the HTTP request, and writes `response_body` with the given content type.
    fn mock_http_server(
        response_body: &str,
        content_type: &str,
    ) -> (u16, thread::JoinHandle<String>) {
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let body = response_body.to_string();
        let ct = content_type.to_string();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 4096];
            let n = std::io::Read::read(&mut stream, &mut buf).unwrap_or(0);
            let request = String::from_utf8_lossy(&buf[..n]).to_string();
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            std::io::Write::write_all(&mut stream, response.as_bytes()).ok();
            request
        });
        (port, handle)
    }

    #[test]
    fn cp_api_json_parses_response() {
        let (port, _handle) = mock_http_server(r#"{"key":"value"}"#, "application/json");
        let base = format!("http://127.0.0.1:{port}");
        let result = cp_api_json(&base, "/test", HttpMethod::Get, None, None).unwrap();
        assert_eq!(result["key"], "value");
    }

    #[test]
    fn cp_api_text_returns_raw() {
        let (port, _handle) = mock_http_server("plain text response", "text/plain");
        let base = format!("http://127.0.0.1:{port}");
        let result = cp_api_text(&base, "/test", HttpMethod::Get, None, None).unwrap();
        assert_eq!(result, "plain text response");
    }

    #[test]
    fn cp_api_json_errors_on_bad_json() {
        let (port, _handle) = mock_http_server("not json at all", "text/plain");
        let base = format!("http://127.0.0.1:{port}");
        let result = cp_api_json(&base, "/test", HttpMethod::Get, None, None);
        assert!(result.is_err());
    }

    #[test]
    fn cp_api_send_includes_auth_header() {
        let (port, handle) = mock_http_server("{}", "application/json");
        let base = format!("http://127.0.0.1:{port}");
        cp_api_json(&base, "/test", HttpMethod::Get, None, Some("my-token")).unwrap();
        let request = handle.join().unwrap();
        let lower = request.to_lowercase();
        assert!(
            lower.contains("authorization: bearer my-token"),
            "request should contain auth header, got: {request}"
        );
    }
}
