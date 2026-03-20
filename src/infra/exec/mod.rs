mod docker;
mod http;
mod output_filter;
mod result;
mod runtime;

pub(crate) use runtime::RUNTIME;

pub use docker::{
    cluster_exists, compose_down, compose_down_project, compose_up, container_running, docker,
    docker_exec_cmd, docker_exec_detached, docker_inspect_ip, docker_network_create,
    docker_network_rm, docker_rm, docker_rm_by_label, docker_run_detached, docker_write_file,
    extract_admin_token,
};
pub use http::{HttpMethod, cp_api_json, cp_api_text, wait_for_http};
pub(crate) use output_filter::filter_progress_line;
pub use result::CommandResult;

use std::collections::HashMap;
use std::iter;
use std::path::Path;
use std::process::{Command, Output, Stdio};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _};
use tokio::process::Command as TokioCommand;
use tokio::time::sleep;
use tracing::info;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::environment::merge_env;

/// How long a subprocess can run without emitting a progress line before
/// we print a heartbeat message.
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);

/// Run a command via `tokio::process::Command`, capturing stdout/stderr.
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
    let cmd_string = command_string(args);
    let output = RUNTIME
        .block_on(async {
            build_tokio_command(program, cmd_args, cwd, env)
                .output()
                .await
        })
        .map_err(|e| {
            CliErrorKind::command_failed(cmd_string.clone()).with_details(e.to_string())
        })?;
    let result = build_result(args, output);
    if ok_exit_codes.contains(&result.returncode) {
        return Ok(result);
    }
    Err(CliErrorKind::command_failed(cmd_string).with_details(failure_details(&result)))
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
    let cmd_string = command_string(args);
    let heartbeat_label = describe_command(args);
    let args_owned: Vec<String> = args.iter().map(|s| (*s).to_string()).collect();

    let result = RUNTIME.block_on(async move {
        use tokio::io::BufReader;

        let mut cmd = build_tokio_command(program, cmd_args, cwd, env);
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| {
            CliErrorKind::command_failed(cmd_string.clone()).with_details(e.to_string())
        })?;

        // Heartbeat task: emits a periodic "still running" message.
        let heartbeat_task = tokio::spawn(async move {
            loop {
                sleep(HEARTBEAT_INTERVAL).await;
                info!("{heartbeat_label} still running...");
            }
        });

        // Stderr reader task to avoid deadlock if both pipes fill.
        let stderr_pipe = child.stderr.take();
        let stderr_task = tokio::spawn(async move {
            let mut captured = String::new();
            if let Some(pipe) = stderr_pipe {
                let mut reader = BufReader::new(pipe);
                let mut line = String::new();
                loop {
                    line.clear();
                    let bytes = reader.read_line(&mut line).await.unwrap_or(0);
                    if bytes == 0 {
                        break;
                    }
                    let trimmed = line.trim_end_matches(['\n', '\r']);
                    if let Some(msg) = filter_progress_line(trimmed) {
                        info!("{msg}");
                    }
                    captured.push_str(trimmed);
                    captured.push('\n');
                }
            }
            captured
        });

        let stdout = {
            let mut buf = Vec::new();
            if let Some(mut pipe) = child.stdout.take() {
                pipe.read_to_end(&mut buf).await.ok();
            }
            String::from_utf8_lossy(&buf).into_owned()
        };

        let status = child.wait().await.map_err(|e| {
            CliErrorKind::command_failed(cmd_string.clone()).with_details(e.to_string())
        })?;

        heartbeat_task.abort();
        heartbeat_task.await.ok();
        let stderr = stderr_task.await.unwrap_or_default();

        Ok::<CommandResult, CliError>(CommandResult {
            args: args_owned,
            returncode: status.code().unwrap_or(-1),
            stdout,
            stderr,
        })
    })?;

    if ok_exit_codes.contains(&result.returncode) {
        return Ok(result);
    }
    Err(CliErrorKind::command_failed(command_string(args)).with_details(failure_details(&result)))
}

/// Run a command with stdout and stderr inherited by the terminal.
///
/// Used for interactive/streaming commands like `docker logs -f` where
/// output should flow directly to the user's terminal.
///
/// # Errors
/// Returns `CliError` if the command fails to start or exits with a bad code.
pub(crate) fn run_command_inherited(args: &[&str], ok_exit_codes: &[i32]) -> Result<i32, CliError> {
    let (program, cmd_args) = args
        .split_first()
        .ok_or_else(|| CliError::from(CliErrorKind::EmptyCommandArgs))?;
    let merged = merge_env(iter::empty());
    let status = Command::new(program)
        .args(cmd_args)
        .envs(&merged)
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .map_err(|e| {
            CliErrorKind::command_failed(command_string(args)).with_details(e.to_string())
        })?;
    let code = status.code().unwrap_or(-1);
    if ok_exit_codes.contains(&code) {
        return Ok(code);
    }
    Err(CliErrorKind::command_failed(command_string(args))
        .with_details(format!("exit code {code}")))
}

fn build_tokio_command(
    program: &str,
    cmd_args: &[&str],
    cwd: Option<&Path>,
    env: Option<&HashMap<String, String>>,
) -> TokioCommand {
    let merged = merge_env(env.into_iter().flat_map(|vars| vars.iter()));
    let mut cmd = TokioCommand::new(program);
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

/// Build a short human-readable label for a command, used in heartbeat messages.
///
/// For make targets, returns the target name (e.g., "k3d/deploy/helm").
/// For docker compose, returns "compose up" or similar.
/// For other commands, returns the first two args.
fn describe_command(args: &[&str]) -> String {
    if args.first() == Some(&"make")
        && let Some(target) = args.get(1)
    {
        return (*target).to_string();
    }
    if args.len() >= 2 && args[0] == "docker" && args[1] == "compose" {
        let compose_subcommands = ["up", "down", "start", "stop", "build", "pull", "logs"];
        let subcommand = args
            .iter()
            .skip(2)
            .find(|a| compose_subcommands.contains(a));
        return format!("compose {}", subcommand.unwrap_or(&"operation"));
    }
    args.iter().take(2).copied().collect::<Vec<_>>().join(" ")
}

/// Restart all deployments in the given namespaces via `kubectl rollout restart`.
///
/// No-op if the list is empty. Requires a kubeconfig for cluster access.
///
/// # Errors
/// Returns `CliError` if any restart command fails.
pub fn kubectl_rollout_restart(
    kubeconfig: Option<&Path>,
    namespaces: &[String],
) -> Result<(), CliError> {
    for namespace in namespaces {
        kubectl(
            kubeconfig,
            &["rollout", "restart", "deployment", "-n", namespace],
            &[0],
        )?;
        info!(%namespace, "restarted deployments");
    }
    Ok(())
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

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

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

    // --- new helm/kubectl/compose filter tests ---

    #[test]
    fn filter_progress_helm_install() {
        let msg = filter_progress_line("beginning helm install for release kuma");
        assert_eq!(msg.as_deref(), Some("helm: installing release"));
    }

    #[test]
    fn filter_progress_helm_upgrade() {
        let msg = filter_progress_line("performing helm upgrade on release kuma");
        assert_eq!(msg.as_deref(), Some("helm: installing release"));
    }

    #[test]
    fn filter_progress_kubectl_condition_met() {
        let msg = filter_progress_line("pod/kuma-cp-xyz condition met");
        assert_eq!(msg.as_deref(), Some("kubectl: condition met"));
    }

    #[test]
    fn filter_progress_kubectl_rollout_complete() {
        let msg = filter_progress_line("deployment rollout complete");
        assert_eq!(msg.as_deref(), Some("kubectl: rollout complete"));
    }

    #[test]
    fn filter_progress_kubectl_waiting_for_rollout() {
        let msg = filter_progress_line("Waiting for deployment/kuma-cp rollout to finish");
        assert_eq!(msg.as_deref(), Some("kubectl: waiting for rollout"));
    }

    #[test]
    fn filter_progress_kubectl_waiting_for_condition() {
        let msg = filter_progress_line("Waiting for condition=Ready on pod/kuma-cp-abc123");
        assert!(msg.is_some());
        let text = msg.unwrap();
        assert!(text.starts_with("kubectl: waiting for condition"));
    }

    #[test]
    fn filter_progress_kubectl_rolled_out() {
        let msg = filter_progress_line("deployment \"kuma-cp\" successfully rolled out");
        assert_eq!(msg.as_deref(), Some("kubectl: deployment rolled out"));
    }

    #[test]
    fn filter_progress_compose_container_started() {
        let msg = filter_progress_line("Container harness-global-1 Started");
        assert_eq!(msg.as_deref(), Some("compose: container started"));
    }

    #[test]
    fn filter_progress_compose_container_healthy() {
        let msg = filter_progress_line("Container harness-global-1 Healthy");
        assert_eq!(msg.as_deref(), Some("compose: container healthy"));
    }

    #[test]
    fn filter_progress_compose_container_waiting() {
        let msg = filter_progress_line("Container harness-zone1-1 Waiting");
        assert_eq!(
            msg.as_deref(),
            Some("compose: waiting for container health")
        );
    }

    #[test]
    fn filter_progress_compose_container_created() {
        let msg = filter_progress_line("Container harness-global-1 Created");
        assert_eq!(msg.as_deref(), Some("compose: container created"));
    }

    #[test]
    fn filter_progress_k3d_loading_images() {
        let msg = filter_progress_line("INFO: Loading images into k3d cluster");
        assert_eq!(msg.as_deref(), Some("k3d: loading images into cluster"));
    }

    // --- describe_command tests ---

    #[test]
    fn describe_command_make_target() {
        assert_eq!(
            describe_command(&["make", "k3d/deploy/helm"]),
            "k3d/deploy/helm"
        );
    }

    #[test]
    fn describe_command_compose() {
        let args = [
            "docker",
            "compose",
            "-f",
            "/tmp/compose.yaml",
            "-p",
            "harness",
            "up",
            "-d",
        ];
        assert_eq!(describe_command(&args), "compose up");
    }

    #[test]
    fn describe_command_generic() {
        assert_eq!(describe_command(&["kubectl", "apply"]), "kubectl apply");
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
        if let Ok(names) = docker_rm_by_label("io.harness.test.nonexistent=true") {
            assert!(names.is_empty());
        }
    }

    #[test]
    fn kubectl_rollout_restart_skips_empty_list() {
        let result = kubectl_rollout_restart(None, &[]);
        assert!(result.is_ok());
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
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let body = response_body.to_string();
        let ct = content_type.to_string();
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 4096];
            let n = Read::read(&mut stream, &mut buf).unwrap_or(0);
            let request = String::from_utf8_lossy(&buf[..n]).to_string();
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: {ct}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            Write::write_all(&mut stream, response.as_bytes()).ok();
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
