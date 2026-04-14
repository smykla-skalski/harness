use super::*;

pub(super) fn wait_for_daemon_ready(home: &Path, xdg: &Path) -> DaemonStatusReport {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let retry_reason = match try_daemon_status(home, xdg) {
            Ok(status) => {
                if let Some(manifest) = status.manifest.as_ref()
                    && endpoint_is_healthy(&manifest.endpoint, &manifest.token_path)
                    && session_api_is_ready(home, xdg)
                {
                    return status;
                }
                "daemon status did not report a healthy manifest with a ready session API yet"
                    .to_string()
            }
            Err(error) => error,
        };
        assert!(
            Instant::now() < deadline,
            "daemon did not become healthy before timeout: {}",
            retry_reason
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

pub(super) fn wait_for_app_group_daemon_ready(home: &Path) -> Value {
    let root = app_group_daemon_root(home);
    let manifest_path = root.join("manifest.json");
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        if let Ok(data) = std::fs::read_to_string(&manifest_path)
            && let Ok(manifest) = serde_json::from_str::<Value>(&data)
            && let Some(endpoint) = manifest.get("endpoint").and_then(Value::as_str)
            && let Some(token_path) = manifest.get("token_path").and_then(Value::as_str)
            && endpoint_is_healthy(endpoint, token_path)
        {
            return manifest;
        }
        assert!(
            Instant::now() < deadline,
            "app-group daemon did not become healthy before timeout at {}",
            manifest_path.display()
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

pub(super) fn wait_for_daemon_stopped(home: &Path, xdg: &Path) {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let retry_reason = match try_daemon_status(home, xdg) {
            Ok(status) => {
                if status.manifest.is_none() {
                    return;
                }
                "daemon status still reports a manifest".to_string()
            }
            Err(error) => error,
        };
        assert!(
            Instant::now() < deadline,
            "daemon did not stop before timeout: {}",
            retry_reason
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

pub(super) fn wait_for_bridge_capabilities(
    home: &Path,
    xdg: &Path,
    required_capabilities: &[&str],
) -> BridgeStatusReport {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let output = run_harness(home, xdg, &["bridge", "status"]);
        if output.status.success() {
            let report: BridgeStatusReport =
                serde_json::from_slice(&output.stdout).expect("parse bridge status");
            if report.running
                && required_capabilities
                    .iter()
                    .all(|capability| report.capabilities.contains_key(*capability))
            {
                return report;
            }
        }
        assert!(
            Instant::now() < deadline,
            "bridge did not become ready before timeout: {}",
            output_text(&output)
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn try_daemon_status(home: &Path, xdg: &Path) -> Result<DaemonStatusReport, String> {
    let output = run_harness(home, xdg, &["daemon", "status"]);
    if !output.status.success() {
        return Err(output_text(&output));
    }
    serde_json::from_slice(&output.stdout).map_err(|error| {
        format!(
            "parse daemon status: {error}; raw={}",
            String::from_utf8_lossy(&output.stdout)
        )
    })
}

fn endpoint_is_healthy(endpoint: &str, token_path: &str) -> bool {
    let url = format!("{}/v1/health", endpoint.trim_end_matches('/'));
    let Ok(token) = std::fs::read_to_string(token_path) else {
        return false;
    };
    let token = token.trim().to_string();
    if token.is_empty() {
        return false;
    }
    Runtime::new().expect("runtime").block_on(async {
        reqwest::Client::new()
            .get(&url)
            .bearer_auth(token)
            .timeout(DAEMON_HTTP_TIMEOUT)
            .send()
            .await
            .is_ok_and(|response| response.status().is_success())
    })
}

fn session_api_is_ready(home: &Path, xdg: &Path) -> bool {
    let output = run_harness(home, xdg, &["session", "list", "--json"]);
    output.status.success()
}

pub(super) fn post_json(endpoint: &str, token: &str, path: &str, body: Value) -> (u16, Value) {
    let url = format!(
        "{}/{}",
        endpoint.trim_end_matches('/'),
        path.trim_start_matches('/')
    );
    let token = token.to_string();
    let runtime = Runtime::new().expect("runtime");
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        let request_body = body.clone();
        let client = reqwest::Client::new();
        let response = runtime.block_on(async {
            client
                .post(&url)
                .bearer_auth(token.clone())
                .json(&request_body)
                .timeout(DAEMON_HTTP_TIMEOUT)
                .send()
                .await
        });
        match response {
            Ok(response) => {
                let status = response.status().as_u16();
                let json =
                    runtime.block_on(async { response.json::<Value>().await.expect("json body") });
                return (status, json);
            }
            Err(error) if daemon_request_error_is_retryable(&error) => {
                if Instant::now() >= deadline {
                    panic!("daemon post: {error:?}");
                }
                thread::sleep(DAEMON_WAIT_INTERVAL);
            }
            Err(error) => panic!("daemon post: {error:?}"),
        }
    }
}

pub(super) fn current_app_group_daemon_endpoint_and_token(home: &Path) -> (String, String) {
    let root = app_group_daemon_root(home);
    let manifest: Value = serde_json::from_str(
        &std::fs::read_to_string(root.join("manifest.json")).expect("read app-group manifest"),
    )
    .expect("parse app-group manifest");
    let endpoint = manifest["endpoint"]
        .as_str()
        .expect("manifest endpoint")
        .to_string();
    let token = std::fs::read_to_string(root.join("auth-token"))
        .expect("read app-group token")
        .trim()
        .to_string();
    (endpoint, token)
}

fn app_group_daemon_root(home: &Path) -> PathBuf {
    home.join("Library")
        .join("Group Containers")
        .join(HARNESS_MONITOR_APP_GROUP_ID)
        .join("harness")
        .join("daemon")
}

fn read_daemon_token(token_path: &str) -> String {
    std::fs::read_to_string(token_path)
        .expect("read daemon token")
        .trim()
        .to_string()
}

pub(super) fn start_session_via_http(
    home: &Path,
    xdg: &Path,
    project_arg: &str,
    session_id: &str,
    title: &str,
    context: &str,
) -> SessionState {
    let runtime = Runtime::new().expect("runtime");
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    let request_body = json!({
        "title": title,
        "context": context,
        "runtime": "codex",
        "session_id": session_id,
        "project_dir": project_arg,
    });

    loop {
        let (endpoint, token) = current_daemon_endpoint_and_token(home, xdg);
        let url = format!("{}/v1/sessions", endpoint.trim_end_matches('/'));
        let client = reqwest::Client::new();
        let response = runtime.block_on(async {
            client
                .post(&url)
                .bearer_auth(&token)
                .json(&request_body)
                .timeout(DAEMON_HTTP_TIMEOUT)
                .send()
                .await
        });

        match response {
            Ok(response) => {
                let status = response.status().as_u16();
                let body =
                    runtime.block_on(async { response.json::<Value>().await.expect("json body") });
                if status == 200 {
                    return serde_json::from_value::<SessionMutationResponse>(body)
                        .expect("parse session start")
                        .state;
                }
                if status == 409
                    && let Some(state) = read_session_status(home, xdg, project_arg, session_id)
                {
                    return state;
                }
                panic!("unexpected body: {body}");
            }
            Err(error) if daemon_request_error_is_retryable(&error) => {
                if let Some(state) = read_session_status(home, xdg, project_arg, session_id) {
                    return state;
                }
                if Instant::now() >= deadline {
                    panic!("daemon post: {error:?}");
                }
                thread::sleep(DAEMON_WAIT_INTERVAL);
            }
            Err(error) => panic!("daemon post: {error:?}"),
        }
    }
}

pub(super) fn current_daemon_endpoint_and_token(home: &Path, xdg: &Path) -> (String, String) {
    let deadline = Instant::now() + DAEMON_WAIT_TIMEOUT;
    loop {
        if let Ok(status) = try_daemon_status(home, xdg)
            && let Some(manifest) = status.manifest.as_ref()
        {
            return (
                manifest.endpoint.clone(),
                read_daemon_token(&manifest.token_path),
            );
        }

        assert!(
            Instant::now() < deadline,
            "daemon manifest did not become available before timeout"
        );
        thread::sleep(DAEMON_WAIT_INTERVAL);
    }
}

fn read_session_status(
    home: &Path,
    xdg: &Path,
    project_arg: &str,
    session_id: &str,
) -> Option<SessionState> {
    let output = run_harness(
        home,
        xdg,
        &[
            "session",
            "status",
            session_id,
            "--json",
            "--project-dir",
            project_arg,
        ],
    );
    output
        .status
        .success()
        .then(|| serde_json::from_slice(&output.stdout).expect("parse session status"))
}

fn daemon_request_error_is_retryable(error: &reqwest::Error) -> bool {
    if error.is_connect() || error.is_timeout() {
        return true;
    }

    error.is_request()
}

pub(super) fn create_mock_codex(base: &Path) -> PathBuf {
    let script = base.join("mock-codex");
    std::fs::write(
        &script,
        r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo 'mock-codex 0.0.1'
  exit 0
fi

exec python3 - "$@" <<'PY'
import socket
import sys

args = sys.argv[1:]
if len(args) < 3 or args[0] != "app-server" or args[1] != "--listen":
    print(f"unexpected args: {args}", file=sys.stderr)
    sys.exit(2)

listen = args[2]
if not listen.startswith("ws://"):
    print(f"unexpected listen address: {listen}", file=sys.stderr)
    sys.exit(3)

address = listen[len("ws://"):]
host, port = address.rsplit(":", 1)
port = int(port)

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind((host, port))
server.listen()

while True:
    conn, _ = server.accept()
    request = b""
    while b"\r\n\r\n" not in request:
        chunk = conn.recv(4096)
        if not chunk:
            break
        request += chunk

    if request.startswith(b"GET /readyz ") or request.startswith(b"GET /healthz "):
        body = b"ok\n"
        response = (
            b"HTTP/1.1 200 OK\r\n"
            + f"Content-Length: {len(body)}\r\n".encode()
            + b"Connection: close\r\n\r\n"
            + body
        )
    else:
        body = b"missing\n"
        response = (
            b"HTTP/1.1 404 Not Found\r\n"
            + f"Content-Length: {len(body)}\r\n".encode()
            + b"Connection: close\r\n\r\n"
            + body
        )
    conn.sendall(response)
    conn.close()
PY
"#,
    )
    .expect("write mock codex");
    std::fs::set_permissions(
        &script,
        std::fs::Permissions::from(std::os::unix::fs::PermissionsExt::from_mode(0o755)),
    )
    .expect("chmod mock codex");
    script
}
