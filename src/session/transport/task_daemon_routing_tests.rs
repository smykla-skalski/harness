//! Review transport daemon-routing coverage.
//!
//! The five review task commands (`submit-for-review`, `claim-review`,
//! `submit-review`, `respond-review`, `arbitrate`) and `improver apply`
//! must prefer the daemon client when a running daemon is reachable.
//! The existing `review_cli` integration tests only exercise the
//! file-backed fallback, so deleting the `DaemonClient::try_connect()`
//! branch from each command would go unnoticed. These tests stand up a
//! fake running daemon via `install_fake_running_xdg_daemon`, run each
//! `Execute::execute()` end-to-end, and assert the exact `POST` path and
//! JSON body the CLI sent.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use harness_testkit::with_isolated_harness_env;
use serde_json::json;
use tempfile::tempdir;

use crate::app::command_context::{AppContext, Execute};
use crate::daemon::client::test_support::install_fake_running_xdg_daemon;
use crate::session::service;
use crate::session::types::{ReviewVerdict, TaskSeverity, TaskSource};

use super::improver::SessionImproverApplyArgs;
use super::task::{
    TaskArbitrateArgs, TaskClaimReviewArgs, TaskRespondReviewArgs, TaskSubmitForReviewArgs,
    TaskSubmitReviewArgs,
};

struct CapturedRequest {
    path: String,
    body: String,
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
        "tasks": [],
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
            if first_line.starts_with("GET /v1/sessions") {
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

fn run_against_fake_daemon<F>(session_id: &str, run: F) -> CapturedRequest
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
        drop(handle);
        let mut slot = captured.lock().expect("lock");
        slot.take().expect("daemon must capture POST")
    })
}

fn run_improver_against_fake_daemon<F>(run: F) -> CapturedRequest
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
        drop(handle);
        let mut slot = captured.lock().expect("lock");
        slot.take().expect("daemon must capture POST")
    })
}

#[test]
fn submit_for_review_args_routes_through_daemon_client() {
    // Silence unused import when a subset of tests is selected.
    let _ = (TaskSeverity::Medium, TaskSource::Manual);
    let captured = run_against_fake_daemon("sess-route-sfr", || {
        let args = TaskSubmitForReviewArgs {
            session_id: "sess-route-sfr".into(),
            task_id: "task-1".into(),
            actor: "worker-1".into(),
            summary: Some("done".into()),
            suggested_persona: Some("code-reviewer".into()),
            project_dir: None,
        };
        let exit = args.execute(&AppContext::default()).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/sess-route-sfr/tasks/task-1/submit-for-review"
    );
    assert!(
        captured.body.contains("\"actor\":\"worker-1\""),
        "body must carry actor: {}",
        captured.body
    );
    assert!(
        captured
            .body
            .contains("\"suggested_persona\":\"code-reviewer\""),
        "body must carry persona hint: {}",
        captured.body
    );
}

#[test]
fn claim_review_args_routes_through_daemon_client() {
    let captured = run_against_fake_daemon("sess-route-claim", || {
        let args = TaskClaimReviewArgs {
            session_id: "sess-route-claim".into(),
            task_id: "task-1".into(),
            actor: "rev-1".into(),
            project_dir: None,
        };
        let exit = args.execute(&AppContext::default()).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/sess-route-claim/tasks/task-1/claim-review"
    );
    assert!(captured.body.contains("\"actor\":\"rev-1\""));
}

#[test]
fn submit_review_args_routes_through_daemon_client() {
    let captured = run_against_fake_daemon("sess-route-sr", || {
        let args = TaskSubmitReviewArgs {
            session_id: "sess-route-sr".into(),
            task_id: "task-1".into(),
            actor: "rev-1".into(),
            verdict: ReviewVerdict::RequestChanges,
            summary: "needs work".into(),
            points: Some(r#"[{"point_id":"p1","text":"fix","state":"open"}]"#.into()),
            project_dir: None,
        };
        let exit = args.execute(&AppContext::default()).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/sess-route-sr/tasks/task-1/submit-review"
    );
    assert!(
        captured.body.contains("\"verdict\":\"request_changes\""),
        "body must serialize snake_case verdict: {}",
        captured.body
    );
    assert!(
        captured.body.contains("\"point_id\":\"p1\""),
        "body must include parsed review points: {}",
        captured.body
    );
}

#[test]
fn respond_review_args_routes_through_daemon_client() {
    let captured = run_against_fake_daemon("sess-route-respond", || {
        let args = TaskRespondReviewArgs {
            session_id: "sess-route-respond".into(),
            task_id: "task-1".into(),
            actor: "worker-1".into(),
            agreed: vec!["p1".into()],
            disputed: vec!["p2".into(), "p3".into()],
            note: Some("reworking".into()),
            project_dir: None,
        };
        let exit = args.execute(&AppContext::default()).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/sess-route-respond/tasks/task-1/respond-review"
    );
    assert!(captured.body.contains("\"agreed\":[\"p1\"]"));
    assert!(captured.body.contains("\"disputed\":[\"p2\",\"p3\"]"));
}

#[test]
fn arbitrate_args_routes_through_daemon_client() {
    let captured = run_against_fake_daemon("sess-route-arb", || {
        let args = TaskArbitrateArgs {
            session_id: "sess-route-arb".into(),
            task_id: "task-1".into(),
            actor: "leader".into(),
            verdict: ReviewVerdict::Approve,
            summary: "shipping".into(),
            project_dir: None,
        };
        let exit = args.execute(&AppContext::default()).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(
        captured.path,
        "/v1/sessions/sess-route-arb/tasks/task-1/arbitrate"
    );
    assert!(captured.body.contains("\"verdict\":\"approve\""));
    assert!(captured.body.contains("\"summary\":\"shipping\""));
}

#[test]
fn improver_apply_args_routes_through_daemon_client() {
    let tmp = tempdir().expect("tempdir for contents");
    let contents_path = tmp.path().join("new.md");
    std::fs::write(&contents_path, "new contents\n").expect("write contents");

    let captured = run_improver_against_fake_daemon(|| {
        let args = SessionImproverApplyArgs {
            session_id: "sess-route-imp".into(),
            actor: "improver-1".into(),
            issue_id: "issue/abc".into(),
            target: crate::session::service::ImproverTarget::Skill,
            rel_path: "demo/SKILL.md".into(),
            new_contents_file: contents_path.to_string_lossy().to_string(),
            dry_run: true,
            project_dir: None,
        };
        let exit = args.execute(&AppContext::default()).expect("execute");
        assert_eq!(exit, 0);
    });
    assert_eq!(captured.path, "/v1/sessions/sess-route-imp/improver/apply");
    assert!(captured.body.contains("\"actor\":\"improver-1\""));
    assert!(captured.body.contains("\"issue_id\":\"issue/abc\""));
    assert!(captured.body.contains("\"target\":\"skill\""));
    assert!(captured.body.contains("\"rel_path\":\"demo/SKILL.md\""));
    assert!(captured.body.contains("\"dry_run\":true"));
    assert!(
        captured
            .body
            .contains("\"new_contents\":\"new contents\\n\""),
        "body must inline file contents: {}",
        captured.body
    );
}
