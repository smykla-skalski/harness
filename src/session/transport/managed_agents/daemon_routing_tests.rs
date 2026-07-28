//! Managed-agent transport daemon-routing coverage.
//!
//! Every command here used to reach a typed method on the root
//! `daemon::client` facade. They now build their own request against the leaf
//! `harness-daemon-client`'s generic `get`/`post`/`delete`, so a mismatch
//! between a hand-written URL and the daemon's actual route (or a dropped
//! request field) would compile fine but silently break at runtime. These
//! tests stand up a fake running daemon via `install_fake_running_xdg_daemon`,
//! run each `Execute::execute()` end-to-end, and assert the exact HTTP method,
//! path, and JSON body sent.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use harness_testkit::with_isolated_harness_env;
use harness_workspace::command_context::{AppContext, Execute};
use tempfile::tempdir;

use crate::daemon::client::test_support::install_fake_running_xdg_daemon;
use crate::session::service;
use crate::session::types::{AgentStatus, SessionRole};
use crate::session::wire::{ManagedAgentSnapshot, SessionMutationResponse};
use harness_protocol::agent::HookAgent;
use harness_protocol::managed_agents::acp::AcpAgentSnapshot;
use harness_protocol::managed_agents::codex::{
    CodexApprovalDecision, CodexRunMode, CodexRunSnapshot, CodexRunStatus,
};
use harness_protocol::managed_agents::tui::{
    AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
};

use crate::session::transport::SessionAdoptArgs;

use super::acp_sessions::{AcpCloseSessionArgs, AcpDeleteSessionArgs, AcpSessionsArgs};
use super::codex::{CodexAgentApprovalArgs, CodexAgentInterruptArgs, CodexAgentSteerArgs};
use super::start::{
    AcpAgentStartArgs, AcpInspectArgs, AcpLogoutArgs, CodexAgentStartArgs, TerminalAgentStartArgs,
};
use super::{ManagedAgentListArgs, ManagedAgentShowArgs};

struct CapturedRequest {
    method: String,
    path: String,
    body: String,
}

fn terminal_snapshot_json(tui_id: &str, session_id: &str) -> String {
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

fn codex_snapshot_json(run_id: &str, session_id: &str) -> String {
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

fn acp_snapshot_json(acp_id: &str, session_id: &str) -> String {
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

fn ok_response_json() -> String {
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
/// with `response_body`. Every command in this file makes exactly one request
/// after the handshake, so the server stops after capturing it.
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

fn run_against_fake_daemon<F>(response_body: String, run: F) -> CapturedRequest
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
        drop(handle);
        let mut slot = captured.lock().expect("lock");
        slot.take().expect("daemon must capture a request")
    })
}

#[test]
fn list_managed_agents_routes_through_leaf_client() {
    let response = serde_json::json!({ "agents": [] }).to_string();
    let captured = run_against_fake_daemon(response, || {
        let args = ManagedAgentListArgs {
            session_id: "00000000-0000-4000-8000-00000000b001".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "GET");
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000b001/managed-agents"
    );
}

#[test]
fn get_managed_agent_routes_through_leaf_client() {
    let response = terminal_snapshot_json("tui-1", "00000000-0000-4000-8000-00000000b002");
    let captured = run_against_fake_daemon(response, || {
        let args = ManagedAgentShowArgs {
            agent_id: "tui-1".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "GET");
    assert_eq!(captured.path, "/v1/managed-agents/tui-1");
}

#[test]
fn acp_sessions_list_routes_through_leaf_client_with_query() {
    let response = serde_json::json!({ "sessions": [] }).to_string();
    let captured = run_against_fake_daemon(response, || {
        let args = AcpSessionsArgs {
            acp_id: "acp-1".into(),
            cwd: Some("/work".into()),
            cursor: Some("page-2".into()),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "GET");
    assert!(
        captured
            .path
            .starts_with("/v1/managed-agents/acp-1/sessions?"),
        "path: {}",
        captured.path
    );
    assert!(captured.path.contains("cwd=%2Fwork"), "{}", captured.path);
    assert!(captured.path.contains("cursor=page-2"), "{}", captured.path);
}

#[test]
fn acp_close_session_routes_through_leaf_client() {
    let captured = run_against_fake_daemon(ok_response_json(), || {
        let args = AcpCloseSessionArgs {
            acp_id: "acp-1".into(),
            agent_session_id: "agent-session-7".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(
        captured.path,
        "/v1/managed-agents/acp-1/sessions/agent-session-7/close"
    );
    assert_eq!(captured.body, "{}");
}

#[test]
fn acp_delete_session_routes_through_leaf_client() {
    let captured = run_against_fake_daemon(ok_response_json(), || {
        let args = AcpDeleteSessionArgs {
            acp_id: "acp-1".into(),
            agent_session_id: "agent-session-9".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "DELETE");
    assert_eq!(
        captured.path,
        "/v1/managed-agents/acp-1/sessions/agent-session-9"
    );
}

#[test]
fn codex_steer_routes_through_leaf_client() {
    let response = codex_snapshot_json("run-1", "00000000-0000-4000-8000-00000000b003");
    let captured = run_against_fake_daemon(response, || {
        let args = CodexAgentSteerArgs {
            agent_id: "run-1".into(),
            prompt: "keep going".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/managed-agents/run-1/steer");
    assert!(captured.body.contains("\"prompt\":\"keep going\""));
}

#[test]
fn codex_interrupt_routes_through_leaf_client() {
    let response = codex_snapshot_json("run-1", "00000000-0000-4000-8000-00000000b004");
    let captured = run_against_fake_daemon(response, || {
        let args = CodexAgentInterruptArgs {
            agent_id: "run-1".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/managed-agents/run-1/interrupt");
    assert_eq!(captured.body, "{}");
}

#[test]
fn codex_approval_routes_through_leaf_client() {
    let response = codex_snapshot_json("run-1", "00000000-0000-4000-8000-00000000b005");
    let captured = run_against_fake_daemon(response, || {
        let args = CodexAgentApprovalArgs {
            agent_id: "run-1".into(),
            approval_id: "approval-1".into(),
            decision: CodexApprovalDecision::Accept,
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(
        captured.path,
        "/v1/managed-agents/run-1/approvals/approval-1"
    );
    assert!(captured.body.contains("\"decision\":\"accept\""));
}

#[test]
fn start_terminal_agent_routes_through_leaf_client() {
    let response = terminal_snapshot_json("tui-2", "00000000-0000-4000-8000-00000000b006");
    let captured = run_against_fake_daemon(response, || {
        let args = TerminalAgentStartArgs {
            session_id: "00000000-0000-4000-8000-00000000b006".into(),
            runtime: HookAgent::Claude,
            role: SessionRole::Worker,
            fallback_role: None,
            capabilities: Vec::new(),
            name: None,
            prompt: None,
            project_dir: None,
            argv: Vec::new(),
            rows: 30,
            cols: 120,
            persona: None,
            model: None,
            effort: None,
            allow_custom_model: false,
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000b006/managed-agents/terminal"
    );
    assert!(captured.body.contains("\"runtime\":\"claude\""));
}

#[test]
fn start_codex_agent_routes_through_leaf_client() {
    let response = codex_snapshot_json("run-2", "00000000-0000-4000-8000-00000000b007");
    let captured = run_against_fake_daemon(response, || {
        let args = CodexAgentStartArgs {
            session_id: "00000000-0000-4000-8000-00000000b007".into(),
            prompt: "investigate the failure".into(),
            mode: CodexRunMode::Report,
            role: SessionRole::Worker,
            fallback_role: None,
            capabilities: Vec::new(),
            name: None,
            persona: None,
            resume_thread_id: None,
            model: None,
            effort: None,
            allow_custom_model: false,
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000b007/managed-agents/codex"
    );
    assert!(
        captured
            .body
            .contains("\"prompt\":\"investigate the failure\"")
    );
}

#[test]
fn start_acp_agent_routes_through_leaf_client() {
    let response = acp_snapshot_json("acp-2", "00000000-0000-4000-8000-00000000b008");
    let captured = run_against_fake_daemon(response, || {
        let args = AcpAgentStartArgs {
            session_id: "00000000-0000-4000-8000-00000000b008".into(),
            agent: "copilot".into(),
            role: SessionRole::Worker,
            fallback_role: None,
            capabilities: Vec::new(),
            name: None,
            prompt: None,
            project_dir: None,
            persona: None,
            model: None,
            effort: None,
            allow_custom_model: false,
            record_permissions: false,
            additional_directories: Vec::new(),
            resume_session_id: None,
            no_resume: false,
            endpoint: None,
            header_env: Vec::new(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(
        captured.path,
        "/v1/sessions/00000000-0000-4000-8000-00000000b008/managed-agents/acp"
    );
    assert!(captured.body.contains("\"descriptor_id\":\"copilot\""));
}

#[test]
fn acp_inspect_routes_through_leaf_client_with_session_filter() {
    let response = serde_json::json!({
        "agents": [],
        "daemon_perceived_now": null,
        "available": true,
        "issue_message": null,
    })
    .to_string();
    let captured = run_against_fake_daemon(response, || {
        let args = AcpInspectArgs {
            session_id: Some("00000000-0000-4000-8000-00000000b009".into()),
            json: true,
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "GET");
    assert!(
        captured.path.starts_with("/v1/managed-agents/acp/inspect?"),
        "path: {}",
        captured.path
    );
    assert!(
        captured
            .path
            .contains("session_id=00000000-0000-4000-8000-00000000b009"),
        "{}",
        captured.path
    );
}

#[test]
fn acp_logout_routes_through_leaf_client() {
    let captured = run_against_fake_daemon(ok_response_json(), || {
        let args = AcpLogoutArgs {
            acp_id: "acp-3".into(),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/managed-agents/acp-3/logout");
    assert_eq!(captured.body, "{}");
}

#[test]
fn session_adopt_routes_through_leaf_client() {
    let session_id = "00000000-0000-4000-8000-00000000b010";
    let state = service::build_new_session_with_policy(
        "daemon routing ctx",
        "daemon routing",
        session_id,
        "leaderless",
        None,
        "2026-04-24T00:00:00Z",
        None,
    );
    let response =
        serde_json::to_string(&SessionMutationResponse { state }).expect("serialize state");
    let captured = run_against_fake_daemon(response, || {
        let args = SessionAdoptArgs {
            path: "/tmp/example-session".into(),
            bookmark_id: Some("bookmark-1".into()),
        };
        assert_eq!(args.execute(&AppContext).expect("execute"), 0);
    });
    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/sessions/adopt");
    assert!(captured.body.contains("\"bookmark_id\":\"bookmark-1\""));
    assert!(
        captured
            .body
            .contains("\"session_root\":\"/tmp/example-session\"")
    );
}
