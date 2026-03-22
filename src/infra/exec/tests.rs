use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::Path;
use std::thread;
use std::time::Duration;

use super::runner::{describe_command, run_command};
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
    assert!(result.stdout.trim().ends_with("/tmp"));
}

#[test]
fn run_command_with_env() {
    let mut env = HashMap::new();
    env.insert("TEST_VAR_XYZ".to_string(), "harness_test".to_string());
    let result = run_command(&["sh", "-c", "echo $TEST_VAR_XYZ"], None, Some(&env), &[0]).unwrap();
    assert_eq!(result.stdout.trim(), "harness_test");
}

#[test]
fn docker_run_detached_builds_correct_args() {
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
    assert!(result.is_err());
}

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

#[test]
fn describe_command_make_target() {
    assert_eq!(
        describe_command(&["make", "k3d/cluster/deploy/helm"]),
        "k3d/cluster/deploy/helm"
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
        filter_progress_line("#9 [6/6] COPY /tools/releases/templates/group /etc/group").is_none()
    );
    assert!(filter_progress_line("#12 extracting sha256:abc123").is_none());
}

#[test]
fn docker_rm_by_label_returns_empty_for_no_matches() {
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
fn wait_for_http_succeeds_on_mock_server() {
    let (port, _handle) = mock_http_server("ok", "text/plain");
    let url = format!("http://127.0.0.1:{port}");
    let result = wait_for_http(&url, Duration::from_secs(2));
    assert!(
        result.is_ok(),
        "expected wait_for_http to succeed: {result:?}"
    );
}

#[test]
fn kumactl_run_injects_cp_addr() {
    let result = kumactl_run(
        Path::new("/nonexistent/kumactl"),
        "http://localhost:5681",
        &["version"],
        &[0],
    );
    assert!(result.is_err());
}

fn mock_http_server(response_body: &str, content_type: &str) -> (u16, thread::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let body = response_body.to_string();
    let content_type_owned = content_type.to_string();
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buf = [0u8; 4096];
        let n = Read::read(&mut stream, &mut buf).unwrap_or(0);
        let request = String::from_utf8_lossy(&buf[..n]).to_string();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: {content_type_owned}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
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
