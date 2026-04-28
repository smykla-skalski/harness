use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::json;

use super::DaemonClient;
use super::test_support::{read_http_request, write_http_response};
use crate::daemon::protocol::{
    ImproverApplyRequest, TaskArbitrateRequest, TaskClaimReviewRequest, TaskRespondReviewRequest,
    TaskSubmitForReviewRequest, TaskSubmitReviewRequest,
};
use crate::session::service::ImproverTarget;
use crate::session::types::{ReviewPoint, ReviewPointState, ReviewVerdict};

fn stub_session_detail_json() -> serde_json::Value {
    json!({
        "session": {
            "project_id": "proj-id",
            "project_name": "demo",
            "project_dir": "/origin",
            "context_root": "/origin",
            "worktree_path": "/work",
            "shared_path": "/shared",
            "origin_path": "/origin",
            "branch_ref": "harness/abc",
            "session_id": "sess-1",
            "title": "t",
            "context": "c",
            "status": "active",
            "created_at": "2026-04-20T00:00:00Z",
            "updated_at": "2026-04-20T00:00:00Z",
            "last_activity_at": null,
            "leader_id": null,
            "observe_id": null,
            "pending_leader_transfer": null,
            "metrics": {}
        },
        "agents": [],
        "tasks": [],
        "signals": [],
        "observer": null,
        "agent_activity": []
    })
}

struct Captured {
    path: String,
    body: String,
}

fn spawn_post_mock(
    response_status: &'static str,
    response_body: String,
) -> (String, Arc<Mutex<Captured>>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured = Arc::new(Mutex::new(Captured {
        path: String::new(),
        body: String::new(),
    }));
    let captured_clone = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let request = read_http_request(&mut stream);
        let first_line = request.lines().next().unwrap_or_default();
        let path = first_line
            .split_whitespace()
            .nth(1)
            .unwrap_or_default()
            .to_string();
        let body = request
            .split("\r\n\r\n")
            .nth(1)
            .unwrap_or_default()
            .to_string();
        *captured_clone.lock().expect("capture") = Captured { path, body };
        write_http_response(
            &mut stream,
            response_status,
            "application/json",
            &response_body,
        );
    });
    (endpoint, captured, handle)
}

fn spawn_get_mock(
    response_status: &'static str,
    response_body: String,
) -> (String, Arc<Mutex<Captured>>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured = Arc::new(Mutex::new(Captured {
        path: String::new(),
        body: String::new(),
    }));
    let captured_clone = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let request = read_http_request(&mut stream);
        let first_line = request.lines().next().unwrap_or_default();
        let path = first_line
            .split_whitespace()
            .nth(1)
            .unwrap_or_default()
            .to_string();
        *captured_clone.lock().expect("capture") = Captured {
            path,
            body: String::new(),
        };
        write_http_response(
            &mut stream,
            response_status,
            "application/json",
            &response_body,
        );
    });
    (endpoint, captured, handle)
}

fn client_with(endpoint: String) -> DaemonClient {
    DaemonClient {
        endpoint,
        token: "test-token".into(),
        http: reqwest::Client::new(),
    }
}

#[test]
fn submit_task_for_review_posts_expected_path_and_body() {
    let (endpoint, captured, handle) =
        spawn_post_mock("200 OK", stub_session_detail_json().to_string());
    let client = client_with(endpoint);
    let request = TaskSubmitForReviewRequest {
        actor: "worker-1".into(),
        summary: Some("ready".into()),
        suggested_persona: Some("code-reviewer".into()),
    };
    let detail = client
        .submit_task_for_review("sess-1", "task-9", &request)
        .expect("submit_task_for_review");
    assert_eq!(detail.session.session_id, "sess-1");
    handle.join().expect("server thread");
    let captured = captured.lock().expect("captured");
    assert_eq!(
        captured.path,
        "/v1/sessions/sess-1/tasks/task-9/submit-for-review"
    );
    assert!(captured.body.contains("\"actor\":\"worker-1\""));
    assert!(captured.body.contains("\"summary\":\"ready\""));
    assert!(
        captured
            .body
            .contains("\"suggested_persona\":\"code-reviewer\"")
    );
}

#[test]
fn claim_task_review_posts_expected_path_and_body() {
    let (endpoint, captured, handle) =
        spawn_post_mock("200 OK", stub_session_detail_json().to_string());
    let client = client_with(endpoint);
    let request = TaskClaimReviewRequest {
        actor: "rev-1".into(),
    };
    client
        .claim_task_review("sess-1", "task-9", &request)
        .expect("claim_task_review");
    handle.join().expect("server thread");
    let captured = captured.lock().expect("captured");
    assert_eq!(
        captured.path,
        "/v1/sessions/sess-1/tasks/task-9/claim-review"
    );
    assert!(captured.body.contains("\"actor\":\"rev-1\""));
}

#[test]
fn submit_task_review_posts_expected_path_and_body() {
    let (endpoint, captured, handle) =
        spawn_post_mock("200 OK", stub_session_detail_json().to_string());
    let client = client_with(endpoint);
    let request = TaskSubmitReviewRequest {
        actor: "rev-1".into(),
        verdict: ReviewVerdict::RequestChanges,
        summary: "needs rework".into(),
        points: vec![ReviewPoint {
            point_id: "p1".into(),
            text: "fix this".into(),
            state: ReviewPointState::Open,
            worker_note: None,
        }],
    };
    client
        .submit_task_review("sess-1", "task-9", &request)
        .expect("submit_task_review");
    handle.join().expect("server thread");
    let captured = captured.lock().expect("captured");
    assert_eq!(
        captured.path,
        "/v1/sessions/sess-1/tasks/task-9/submit-review"
    );
    assert!(captured.body.contains("\"verdict\":\"request_changes\""));
    assert!(captured.body.contains("\"point_id\":\"p1\""));
}

#[test]
fn respond_task_review_posts_expected_path_and_body() {
    let (endpoint, captured, handle) =
        spawn_post_mock("200 OK", stub_session_detail_json().to_string());
    let client = client_with(endpoint);
    let request = TaskRespondReviewRequest {
        actor: "worker-1".into(),
        agreed: vec!["p1".into()],
        disputed: vec!["p2".into()],
        note: Some("partial".into()),
    };
    client
        .respond_task_review("sess-1", "task-9", &request)
        .expect("respond_task_review");
    handle.join().expect("server thread");
    let captured = captured.lock().expect("captured");
    assert_eq!(
        captured.path,
        "/v1/sessions/sess-1/tasks/task-9/respond-review"
    );
    assert!(captured.body.contains("\"agreed\":[\"p1\"]"));
    assert!(captured.body.contains("\"disputed\":[\"p2\"]"));
    assert!(captured.body.contains("\"note\":\"partial\""));
}

#[test]
fn arbitrate_task_posts_expected_path_and_body() {
    let (endpoint, captured, handle) =
        spawn_post_mock("200 OK", stub_session_detail_json().to_string());
    let client = client_with(endpoint);
    let request = TaskArbitrateRequest {
        actor: "leader".into(),
        verdict: ReviewVerdict::Approve,
        summary: "shipping".into(),
    };
    client
        .arbitrate_task("sess-1", "task-9", &request)
        .expect("arbitrate_task");
    handle.join().expect("server thread");
    let captured = captured.lock().expect("captured");
    assert_eq!(captured.path, "/v1/sessions/sess-1/tasks/task-9/arbitrate");
    assert!(captured.body.contains("\"verdict\":\"approve\""));
    assert!(captured.body.contains("\"summary\":\"shipping\""));
}

#[test]
fn improver_apply_posts_expected_path_and_returns_outcome() {
    let outcome_json = json!({
        "canonical_path": "/repo/agents/skills/demo/SKILL.md",
        "before_sha256": "a".repeat(64),
        "after_sha256": "b".repeat(64),
        "applied": true,
        "backup_path": null,
        "unified_diff": "--- before\n+++ after\n"
    })
    .to_string();
    let (endpoint, captured, handle) = spawn_post_mock("200 OK", outcome_json);
    let client = client_with(endpoint);
    let request = ImproverApplyRequest {
        actor: "improver".into(),
        issue_id: "issue-1".into(),
        target: ImproverTarget::Skill,
        rel_path: "demo/SKILL.md".into(),
        new_contents: "hello".into(),
        project_dir: "/repo".into(),
        dry_run: false,
    };
    let outcome = client
        .improver_apply("sess-1", &request)
        .expect("improver_apply");
    assert!(outcome.applied);
    assert_eq!(outcome.before_sha256.len(), 64);
    handle.join().expect("server thread");
    let captured = captured.lock().expect("captured");
    assert_eq!(captured.path, "/v1/sessions/sess-1/improver/apply");
    assert!(captured.body.contains("\"issue_id\":\"issue-1\""));
    assert!(captured.body.contains("\"target\":\"skill\""));
    assert!(captured.body.contains("\"rel_path\":\"demo/SKILL.md\""));
}

#[test]
fn runtime_probe_results_gets_probe_endpoint() {
    let body = json!({
        "probes": [{
            "agent_id": "copilot",
            "display_name": "GitHub Copilot",
            "binary_present": false,
            "auth_state": "unavailable",
            "version": null,
            "install_hint": "Install GitHub Copilot CLI"
        }],
        "checked_at": "2026-04-28T00:00:00Z"
    })
    .to_string();
    let (endpoint, captured, handle) = spawn_get_mock("200 OK", body);
    let client = client_with(endpoint);
    let response = client.runtime_probe_results().expect("runtime probes");
    assert_eq!(response.probes[0].agent_id, "copilot");
    handle.join().expect("server thread");
    assert_eq!(
        captured.lock().expect("captured").path,
        "/v1/runtimes/probe"
    );
}

#[test]
fn acp_inspect_gets_optional_session_filter() {
    let body = json!({
        "agents": [{
            "acp_id": "agent-acp-1",
            "session_id": "sess-1",
            "agent_id": "copilot",
            "display_name": "GitHub Copilot",
            "pid": 42,
            "pgid": 42,
            "uptime_ms": 10,
            "last_update_at": "2026-04-28T00:00:00Z",
            "last_client_call_at": null,
            "watchdog_state": "active",
            "pending_permissions": 0,
            "terminal_count": 0,
            "prompt_deadline_remaining_ms": 600000
        }]
    })
    .to_string();
    let (endpoint, captured, handle) = spawn_get_mock("200 OK", body);
    let client = client_with(endpoint);
    let response = client
        .inspect_acp_managed_agents(Some("sess-1"))
        .expect("acp inspect");
    assert_eq!(response.agents[0].acp_id, "agent-acp-1");
    handle.join().expect("server thread");
    assert_eq!(
        captured.lock().expect("captured").path,
        "/v1/managed-agents/acp/inspect?session_id=sess-1"
    );
}
