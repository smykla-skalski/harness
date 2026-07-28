//! Shared fake-daemon fixtures for `daemon_routing_tests`.
//!
//! Every command under test makes exactly one request after the health/ready
//! handshake, so `run_against_fake_daemon` answers that single request with a
//! canned body and captures its method, path, and JSON body for the caller to
//! assert on.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use crate::daemon::client::test_support::install_fake_running_xdg_daemon;
use crate::session::types::AgentStatus;
use crate::session::wire::ManagedAgentSnapshot;
use harness_protocol::managed_agents::acp::AcpAgentSnapshot;
use harness_protocol::managed_agents::codex::{CodexRunMode, CodexRunSnapshot, CodexRunStatus};
use harness_protocol::managed_agents::tui::{
    AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
};

pub(super) struct CapturedRequest {
    pub(super) method: String,
    pub(super) path: String,
    pub(super) body: String,
}

pub(super) fn terminal_snapshot_json(tui_id: &str, session_id: &str) -> String {
    let snapshot = ManagedAgentSnapshot::Terminal(AgentTuiSnapshot {
        tui_id: tui_id.to_string(),
        session_id: session_id.to_string(),
        agent_id: "worker-1".into(),
        runtime: "claude".into(),
        status: AgentTuiStatus::Running,
        argv: Vec::new(),
        project_dir: "/tmp/project".into(),
        size: AgentTuiSize { rows: 24, cols: 80 },
        screen: TerminalScreenSnapshot {
            rows: 24,
            cols: 80,
            cursor_row: 0,
            cursor_col: 0,
            text: "ready".into(),
        },
        transcript_path: "/tmp/transcript".into(),
        exit_code: None,
        signal: None,
        error: None,
        created_at: "2026-05-06T00:00:00Z".into(),
        updated_at: "2026-05-06T00:00:00Z".into(),
    });
    serde_json::to_string(&snapshot).expect("serialize terminal snapshot")
}

pub(super) fn codex_snapshot_json(run_id: &str, session_id: &str) -> String {
    let snapshot = ManagedAgentSnapshot::Codex(CodexRunSnapshot {
        run_id: run_id.to_string(),
        session_id: session_id.to_string(),
        task_id: None,
        board_item_id: None,
        workflow_execution_id: None,
        session_agent_id: Some("worker-codex".into()),
        display_name: Some("Codex".into()),
        project_dir: "/tmp/project".into(),
        thread_id: None,
        turn_id: None,
        mode: CodexRunMode::Report,
        status: CodexRunStatus::Running,
        prompt: "investigate".into(),
        latest_summary: None,
        final_message: None,
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: "2026-05-06T00:00:00Z".into(),
        updated_at: "2026-05-06T00:00:00Z".into(),
        model: None,
        effort: None,
    });
    serde_json::to_string(&snapshot).expect("serialize codex snapshot")
}

pub(super) fn acp_snapshot_json(acp_id: &str, session_id: &str) -> String {
    let snapshot = ManagedAgentSnapshot::Acp(AcpAgentSnapshot {
        acp_id: acp_id.to_string(),
        session_id: session_id.to_string(),
        agent_id: "worker-2".into(),
        display_name: "Copilot".into(),
        status: AgentStatus::Active,
        pid: 42,
        pgid: 42,
        project_dir: "/tmp/project".into(),
        process_key: "proc-1".into(),
        pending_permissions: 0,
        permission_queue_depth: 0,
        pending_permission_batches: Vec::new(),
        permission_mode: String::new(),
        permission_log_path: None,
        terminal_count: 0,
        created_at: "2026-05-06T00:00:00Z".into(),
        updated_at: "2026-05-06T00:00:00Z".into(),
    });
    serde_json::to_string(&snapshot).expect("serialize acp snapshot")
}

pub(super) fn ok_response_json() -> String {
    serde_json::json!({ "ok": true }).to_string()
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

/// Handles the client's health/ready handshake generically, then captures
/// whatever single request the command under test sends next and answers it
/// with `response_body`. Every command in this suite makes exactly one
/// request after the handshake, so the server stops after capturing it.
fn spawn_daemon_server(
    listener: TcpListener,
    response_body: String,
) -> (thread::JoinHandle<()>, Arc<Mutex<Option<CapturedRequest>>>) {
    let captured = Arc::new(Mutex::new(None));
    let captured_inner = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        loop {
            let (mut stream, _) = match listener.accept() {
                Ok(value) => value,
                Err(_) => return,
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
            let mut parts = first_line.split_whitespace();
            let method = parts.next().unwrap_or("").to_string();
            let path = parts.next().unwrap_or("").to_string();
            let body = request.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
            *captured_inner.lock().expect("lock") = Some(CapturedRequest { method, path, body });
            write_response(&mut stream, &response_body);
            return;
        }
    });
    (handle, captured)
}

pub(super) fn run_against_fake_daemon<F>(response_body: String, run: F) -> CapturedRequest
where
    F: FnOnce(),
{
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let token = "fake-daemon-token";
        let _lock = install_fake_running_xdg_daemon(tmp.path(), &endpoint, token);
        let (handle, captured) = spawn_daemon_server(listener, response_body);
        run();
        handle
            .join()
            .expect("fake daemon thread should exit cleanly after one request");
        let mut slot = captured.lock().expect("lock");
        slot.take().expect("daemon must capture a request")
    })
}
