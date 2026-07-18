use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use harness::app::{AppContext, Execute};
use harness::daemon::protocol::{
    PolicyApprovalGrantResolveResponse, PolicyApprovalGrantRevokeResponse,
    PolicyApprovalGrantsListResponse, PolicyCanvasWorkspaceResponse,
    TaskBoardDispatchDeliverResponse, TaskBoardDispatchPickResponse,
};
use harness::daemon::state::{self, DaemonManifest, DaemonOwnership, HostBridgeManifest};
use harness::task_board::dispatch::DispatchLifecycle;
use harness::task_board::transport::{
    TaskBoardCommand, TaskBoardDispatchDeliverArgs, TaskBoardDispatchPickArgs,
    TaskBoardPolicyCommand, TaskBoardPolicyGrantResolveArgs, TaskBoardPolicyGrantRevokeArgs,
    TaskBoardPolicyJsonArgs, TaskBoardPolicyToggleArgs,
};
use harness::task_board::{
    AgentMode, DispatchAppliedTask, EvaluatorIntent, FollowUpPhase, PolicyAction,
    PolicyApprovalGrant, PolicyApprovalState, PolicyReasonCode, ReviewerIntent, TaskBoardItem,
    TaskBoardStatus, WorkerIntent,
};
use harness_testkit::with_isolated_harness_env;
use serde_json::Value;
use tempfile::tempdir;

struct CapturedRequest {
    method: String,
    path: String,
    body: String,
}

struct FakeDaemon {
    server: thread::JoinHandle<()>,
    captured: Arc<Mutex<Option<CapturedRequest>>>,
}

fn read_request(stream: &mut TcpStream) -> String {
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
        .expect("set read timeout");
    let mut buffer = Vec::new();
    let mut header_end = None;
    let mut content_length = 0;
    loop {
        let mut chunk = [0_u8; 1024];
        let read = stream.read(&mut chunk).expect("read request");
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if header_end.is_none()
            && let Some(position) = buffer.windows(4).position(|window| window == b"\r\n\r\n")
        {
            let end = position + 4;
            let headers = String::from_utf8_lossy(&buffer[..position]);
            content_length = headers
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .and_then(|value| value.trim().parse::<usize>().ok())
                })
                .unwrap_or(0);
            header_end = Some(end);
        }
        if header_end.is_some_and(|end| buffer.len() >= end + content_length) {
            break;
        }
    }
    String::from_utf8(buffer).expect("request is utf8")
}

fn write_response(stream: &mut TcpStream, content_type: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .expect("write response");
    stream.flush().expect("flush response");
}

fn spawn_daemon(listener: TcpListener, response_body: String) -> FakeDaemon {
    let captured = Arc::new(Mutex::new(None));
    let captured_request = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        loop {
            let (mut stream, _) = listener.accept().expect("accept request");
            let request = read_request(&mut stream);
            let request_line = request.lines().next().unwrap_or_default();
            if request_line.starts_with("GET /v1/health ") {
                write_response(&mut stream, "text/plain", "ok");
                continue;
            }
            if request_line.starts_with("GET /v1/ready ") {
                write_response(
                    &mut stream,
                    "application/json",
                    r#"{"ready":true,"daemon_epoch":"task-board-cli-test"}"#,
                );
                continue;
            }
            if request_line.starts_with("GET /v1/task-board/capabilities ") {
                write_response(
                    &mut stream,
                    "application/json",
                    r#"{"storage":"database","revision":1,"instance_id":"test"}"#,
                );
                continue;
            }
            let mut parts = request_line.split_whitespace();
            let method = parts.next().unwrap_or_default().to_string();
            let path = parts.next().unwrap_or_default().to_string();
            let body = request
                .split_once("\r\n\r\n")
                .map_or_else(String::new, |(_, body)| body.to_string());
            *captured_request.lock().expect("capture request") =
                Some(CapturedRequest { method, path, body });
            write_response(&mut stream, "application/json", &response_body);
            return;
        }
    });
    FakeDaemon {
        server: handle,
        captured,
    }
}

fn run_command(command: &TaskBoardCommand, response_body: String) -> CapturedRequest {
    let temporary = tempdir().expect("tempdir");
    with_isolated_harness_env(temporary.path(), || {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind daemon");
        let endpoint = format!("http://{}", listener.local_addr().expect("daemon address"));
        let token = "task-board-cli-token";
        state::ensure_daemon_dirs().expect("create daemon root");
        let _daemon_lock = state::acquire_singleton_lock().expect("lock daemon root");
        std::fs::write(state::auth_token_path(), token).expect("write daemon token");
        state::write_manifest(&DaemonManifest {
            version: env!("CARGO_PKG_VERSION").to_string(),
            pid: std::process::id(),
            endpoint,
            started_at: "2026-07-14T00:00:00Z".to_string(),
            token_path: state::auth_token_path().display().to_string(),
            sandboxed: false,
            host_bridge: HostBridgeManifest::default(),
            revision: 0,
            updated_at: String::new(),
            binary_stamp: None,
            ownership: DaemonOwnership::Managed,
        })
        .expect("write daemon manifest");
        let daemon = spawn_daemon(listener, response_body);

        assert_eq!(command.execute(&AppContext).expect("execute command"), 0);
        daemon.server.join().expect("join daemon");
        daemon
            .captured
            .lock()
            .expect("read captured request")
            .take()
            .expect("command request")
    })
}

fn applied_dispatch() -> DispatchAppliedTask {
    let worker = WorkerIntent {
        mode: AgentMode::Headless,
    };
    let reviewer = ReviewerIntent {
        phase: FollowUpPhase::AfterWorkerReview,
        suggested_persona: "code-reviewer".to_string(),
        required_consensus: 2,
    };
    let evaluator = EvaluatorIntent {
        phase: FollowUpPhase::AfterWorkerReview,
        mode: AgentMode::Evaluate,
    };
    let mut item = TaskBoardItem::new(
        "task-1".to_string(),
        "Run held work".to_string(),
        "Test body".to_string(),
        "2026-07-14T00:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::InProgress;
    item.session_id = Some("session-1".to_string());
    item.work_item_id = Some("work-1".to_string());
    DispatchAppliedTask {
        board_item_id: item.id.clone(),
        session_id: "session-1".to_string(),
        work_item_id: "work-1".to_string(),
        lifecycle: DispatchLifecycle::planned(&worker, &reviewer, &evaluator).applied(),
        item,
        read_only_workflow: None,
    }
}

fn pending_grant() -> PolicyApprovalGrant {
    PolicyApprovalGrant {
        id: "grant-1".to_string(),
        board_item_id: "task-1".to_string(),
        action: PolicyAction::SpawnAgent,
        canvas_id: Some("canvas-1".to_string()),
        canvas_revision: 2,
        node_id: "approval-1".to_string(),
        reason_code: PolicyReasonCode::ApprovalRequired,
        state: PolicyApprovalState::Pending,
        resolved_by: None,
        resolved_at: None,
        consumed_at: None,
        expiry_seconds: None,
        created_at: "2026-07-14T00:00:00Z".to_string(),
        updated_at: "2026-07-14T00:00:00Z".to_string(),
    }
}

fn workspace(
    spawn_requires_live_policy: bool,
    spawn_kill_switch: bool,
) -> PolicyCanvasWorkspaceResponse {
    PolicyCanvasWorkspaceResponse {
        schema_version: 1,
        active_canvas_id: "canvas-1".to_string(),
        canvases: Vec::new(),
        global_policy_enforcement_enabled: true,
        spawn_requires_live_policy,
        spawn_kill_switch,
        scenarios: Vec::new(),
    }
}

#[test]
fn dispatch_pick_returns_empty_selection_through_public_command() {
    let response = serde_json::to_string(&TaskBoardDispatchPickResponse { selection: None })
        .expect("serialize pick response");
    let captured = run_command(
        &TaskBoardCommand::DispatchPick(TaskBoardDispatchPickArgs { json: true }),
        response,
    );

    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/task-board/dispatch/pick");
    assert_eq!(
        serde_json::from_str::<Value>(&captured.body).expect("pick body"),
        Value::Object(serde_json::Map::new())
    );
}

#[test]
fn dispatch_deliver_dry_run_routes_through_public_command() {
    let response = serde_json::to_string(&TaskBoardDispatchDeliverResponse {
        intent_id: "intent-1".to_string(),
        applied: applied_dispatch(),
        rendered_prompt: "Rendered worker prompt".to_string(),
        started_agent: None,
    })
    .expect("serialize deliver response");
    let captured = run_command(
        &TaskBoardCommand::DispatchDeliver(TaskBoardDispatchDeliverArgs {
            item_id: "task-1".to_string(),
            dry_run: true,
            json: true,
        }),
        response,
    );

    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/task-board/dispatch/deliver");
    let body: Value = serde_json::from_str(&captured.body).expect("deliver body");
    assert_eq!(body["item_id"], "task-1");
    assert_eq!(body["dry_run"], true);
}

#[test]
fn policy_grants_list_routes_through_public_command() {
    let response = serde_json::to_string(&PolicyApprovalGrantsListResponse {
        grants: vec![pending_grant()],
    })
    .expect("serialize grants response");
    let captured = run_command(
        &TaskBoardCommand::Policy {
            command: TaskBoardPolicyCommand::Grants(TaskBoardPolicyJsonArgs { json: true }),
        },
        response,
    );

    assert_eq!(captured.method, "GET");
    assert_eq!(captured.path, "/v1/policy-approval-grants");
    assert!(captured.body.is_empty());
}

#[test]
fn policy_grant_resolve_routes_through_public_command() {
    let mut grant = pending_grant();
    grant.state = PolicyApprovalState::Approved;
    grant.resolved_by = Some("lead".to_string());
    let response = serde_json::to_string(&PolicyApprovalGrantResolveResponse { grant })
        .expect("serialize grant response");
    let captured = run_command(
        &TaskBoardCommand::Policy {
            command: TaskBoardPolicyCommand::GrantResolve(TaskBoardPolicyGrantResolveArgs {
                grant_id: "grant-1".to_string(),
                approve: true,
                deny: false,
                actor: Some("lead".to_string()),
                json: true,
            }),
        },
        response,
    );

    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/policy-approval-grants/resolve");
    let body: Value = serde_json::from_str(&captured.body).expect("grant resolve body");
    assert_eq!(body["grant_id"], "grant-1");
    assert_eq!(body["approve"], true);
    assert_eq!(body["actor"], "lead");
}

#[test]
fn policy_grant_revoke_routes_through_public_command() {
    let mut grant = pending_grant();
    grant.state = PolicyApprovalState::Revoked;
    grant.resolved_by = Some("lead".to_string());
    let response = serde_json::to_string(&PolicyApprovalGrantRevokeResponse { grant })
        .expect("serialize grant response");
    let captured = run_command(
        &TaskBoardCommand::Policy {
            command: TaskBoardPolicyCommand::GrantRevoke(TaskBoardPolicyGrantRevokeArgs {
                grant_id: "grant-1".to_string(),
                actor: Some("lead".to_string()),
                json: true,
            }),
        },
        response,
    );

    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/policy-approval-grants/revoke");
    let body: Value = serde_json::from_str(&captured.body).expect("grant revoke body");
    assert_eq!(body["grant_id"], "grant-1");
    assert_eq!(body["actor"], "lead");
    assert!(body.get("approve").is_none());
}

#[test]
fn spawn_requires_live_policy_toggle_routes_through_public_command() {
    let response = serde_json::to_string(&workspace(true, false)).expect("serialize workspace");
    let captured = run_command(
        &TaskBoardCommand::Policy {
            command: TaskBoardPolicyCommand::SpawnRequiresLivePolicy(TaskBoardPolicyToggleArgs {
                enabled: true,
                json: true,
            }),
        },
        response,
    );

    assert_eq!(captured.method, "POST");
    assert_eq!(
        captured.path,
        "/v1/policy-canvases/spawn-requires-live-policy"
    );
    let body: Value = serde_json::from_str(&captured.body).expect("toggle body");
    assert_eq!(body["enabled"], true);
}

#[test]
fn spawn_kill_switch_toggle_routes_through_public_command() {
    let response = serde_json::to_string(&workspace(false, true)).expect("serialize workspace");
    let captured = run_command(
        &TaskBoardCommand::Policy {
            command: TaskBoardPolicyCommand::SpawnKillSwitch(TaskBoardPolicyToggleArgs {
                enabled: true,
                json: true,
            }),
        },
        response,
    );

    assert_eq!(captured.method, "POST");
    assert_eq!(captured.path, "/v1/policy-canvases/spawn-kill-switch");
    let body: Value = serde_json::from_str(&captured.body).expect("toggle body");
    assert_eq!(body["enabled"], true);
}
