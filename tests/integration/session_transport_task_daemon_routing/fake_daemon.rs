//! Fake running-daemon HTTP server plus the harness that starts it, drives a
//! CLI command against it, and captures the request it received.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use harness_testkit::with_isolated_harness_env;
use serde_json::json;
use tempfile::tempdir;

use harness::daemon::state::test_support::install_fake_running_xdg_daemon;
use harness::session::service;

pub(super) struct CapturedRequest {
    pub(super) path: String,
    pub(super) body: String,
}

fn session_detail_response(session_id: &str) -> String {
    let state = service::build_new_session_with_policy(
        "daemon routing ctx",
        "daemon routing",
        session_id,
        "leaderless",
        None,
        "2026-04-24T00:00:00Z",
        None,
    );
    let detail = json!({
        "session": {
            "project_id": "p",
            "project_name": state.project_name,
            "project_dir": null,
            "context_root": "/",
            "worktree_path": "/",
            "shared_path": "/",
            "origin_path": "/",
            "branch_ref": "main",
            "session_id": state.session_id,
            "title": state.title,
            "context": state.context,
            "status": "awaiting_leader",
            "created_at": state.created_at,
            "updated_at": state.updated_at,
            "last_activity_at": null,
            "leader_id": null,
            "observe_id": null,
            "pending_leader_transfer": null,
            "metrics": {}
        },
        "agents": [],
        "tasks": [{
            "task_id": "task-1",
            "title": "daemon-routed task",
            "severity": "medium",
            "status": "in_progress",
            "assigned_to": "worker-1",
            "created_at": "2026-04-24T00:00:00Z",
            "updated_at": "2026-04-24T00:00:01Z",
            "checkpoint_summary": {
                "checkpoint_id": "checkpoint-1",
                "recorded_at": "2026-04-24T00:00:01Z",
                "actor_id": "worker-1",
                "summary": "halfway",
                "progress": 50
            }
        }],
        "signals": [],
        "observer": null,
        "agent_activity": []
    });
    detail.to_string()
}

fn improver_outcome_response() -> &'static str {
    "{\"canonical_path\":\"/skills/demo/SKILL.md\",\"before_sha256\":\"old\",\"after_sha256\":\"new\",\"applied\":true,\"backup_path\":null,\"unified_diff\":\"\"}"
}

fn read_request(stream: &mut TcpStream) -> String {
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
        .expect("read timeout");
    let mut buffer = Vec::new();
    let mut headers_done = false;
    let mut content_length = 0_usize;
    let mut header_end = 0_usize;
    loop {
        let mut chunk = [0_u8; 1024];
        let read = stream.read(&mut chunk).expect("read request");
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if !headers_done
            && let Some(pos) = buffer.windows(4).position(|window| window == b"\r\n\r\n")
        {
            headers_done = true;
            header_end = pos + 4;
            let head = String::from_utf8_lossy(&buffer[..pos]);
            for line in head.split("\r\n") {
                if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                    content_length = value.trim().parse().unwrap_or(0);
                }
            }
        }
        if headers_done && buffer.len() >= header_end + content_length {
            break;
        }
    }
    String::from_utf8(buffer).expect("utf8")
}

fn write_response(stream: &mut TcpStream, body: &str) {
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(response.as_bytes()).expect("write");
    stream.flush().expect("flush");
}

fn spawn_daemon_server(
    listener: TcpListener,
    response_body: String,
) -> (thread::JoinHandle<()>, Arc<Mutex<Option<CapturedRequest>>>) {
    let captured = Arc::new(Mutex::new(None));
    let captured_inner = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        loop {
            let Ok((mut stream, _)) = listener.accept() else {
                return;
            };
            let request = read_request(&mut stream);
            let first_line = request.lines().next().unwrap_or("").to_string();
            if first_line.starts_with("GET /v1/health") {
                write_response(&mut stream, "ok");
                continue;
            }
            if first_line.starts_with("GET /v1/ready") {
                write_response(&mut stream, "{\"ready\":true,\"daemon_epoch\":\"t\"}");
                continue;
            }
            if first_line.starts_with("GET /v1/test-shutdown") {
                return;
            }
            if first_line.starts_with("GET /v1/sessions/") {
                let path = first_line
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("")
                    .to_string();
                *captured_inner.lock().expect("lock") = Some(CapturedRequest {
                    path,
                    body: String::new(),
                });
                write_response(&mut stream, &response_body);
                return;
            }
            if first_line.starts_with("GET /v1/sessions ") {
                write_response(&mut stream, "[]");
                continue;
            }
            if first_line.starts_with("POST ") {
                let path = first_line
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("")
                    .to_string();
                let body = request.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
                *captured_inner.lock().expect("lock") = Some(CapturedRequest { path, body });
                write_response(&mut stream, &response_body);
                return;
            }
        }
    });
    (handle, captured)
}

pub(super) fn run_against_fake_daemon<F>(session_id: &str, run: F) -> CapturedRequest
where
    F: FnOnce(),
{
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let token = "fake-daemon-token";
        let _lock = install_fake_running_xdg_daemon(tmp.path(), &endpoint, token);
        let (handle, captured) = spawn_daemon_server(listener, session_detail_response(session_id));
        run();
        request_fake_daemon_shutdown(&endpoint);
        handle
            .join()
            .expect("fake daemon thread should exit cleanly after the request completed");
        let mut slot = captured.lock().expect("lock");
        slot.take().expect("daemon must capture a request")
    })
}

pub(super) fn run_improver_against_fake_daemon<F>(run: F) -> CapturedRequest
where
    F: FnOnce(),
{
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let token = "fake-daemon-token";
        let _lock = install_fake_running_xdg_daemon(tmp.path(), &endpoint, token);
        let (handle, captured) =
            spawn_daemon_server(listener, improver_outcome_response().to_string());
        run();
        request_fake_daemon_shutdown(&endpoint);
        handle
            .join()
            .expect("fake daemon thread should exit cleanly after the request completed");
        let mut slot = captured.lock().expect("lock");
        slot.take().expect("daemon must capture a request")
    })
}

/// Connect to the fake daemon and ask its server thread to exit its accept
/// loop, so callers can `join` it instead of leaving it blocked in `accept()`
/// forever — nothing else in this suite ever sends a request the loop treats
/// as terminal when the CLI-side request never happens.
fn request_fake_daemon_shutdown(endpoint: &str) {
    let addr = endpoint.trim_start_matches("http://");
    if let Ok(mut stream) = TcpStream::connect(addr) {
        let _ = stream.write_all(
            b"GET /v1/test-shutdown HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n",
        );
        let _ = stream.flush();
    }
}

/// Same fake daemon as `run_against_fake_daemon`, but asserts the opposite:
/// a rejected id must never reach it, even as a malformed path. The health
/// handshake still succeeds, so a pass here cannot be explained by the local
/// fallback running instead of the daemon branch.
pub(super) fn assert_rejected_before_any_request_reaches_daemon<F>(run: F)
where
    F: FnOnce(),
{
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let token = "fake-daemon-token";
        let _lock = install_fake_running_xdg_daemon(tmp.path(), &endpoint, token);
        let (handle, captured) = spawn_daemon_server(listener, session_detail_response("unused"));
        run();
        request_fake_daemon_shutdown(&endpoint);
        handle
            .join()
            .expect("fake daemon thread should exit cleanly after a shutdown request");
        let slot = captured.lock().expect("lock");
        assert!(
            slot.is_none(),
            "an id with a path separator or '..' must be rejected before any request is sent, \
             but the daemon captured {:?}",
            slot.as_ref().map(|request| &request.path)
        );
    });
}
