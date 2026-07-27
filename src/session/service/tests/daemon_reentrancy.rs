//! Proves the `Handle::try_current().is_err()` guard added to every
//! daemon-reachable `session::service` mutation actually discriminates on
//! tokio-runtime context, the same way #776 proved it for
//! `runtime_registration::register_agent_runtime_session`.
//!
//! `leave_session` stands in for the whole guarded set: every guarded
//! function shares the identical guard expression, so one real fake-daemon
//! round trip is enough to prove the mechanism, while the architecture guard
//! test and code review cover that the expression was actually applied
//! everywhere it needs to be.

use std::io::{Read, Write};
use std::net::TcpListener;

use crate::daemon::client::test_support::install_fake_running_xdg_daemon;

use super::*;

fn fake_session_detail(session_id: &str) -> String {
    let summary = wire::SessionSummary {
        project_id: "p".into(),
        project_name: "demo".into(),
        project_dir: None,
        context_root: "/".into(),
        worktree_path: "/".into(),
        shared_path: "/".into(),
        origin_path: "/".into(),
        branch_ref: "main".into(),
        session_id: session_id.to_string(),
        title: "t".into(),
        context: "c".into(),
        status: SessionStatus::Active,
        created_at: "2026-04-24T00:00:00Z".into(),
        updated_at: "2026-04-24T00:00:00Z".into(),
        last_activity_at: None,
        leader_id: None,
        observe_id: None,
        pending_leader_transfer: None,
        external_origin: None,
        adopted_at: None,
        metrics: SessionMetrics::default(),
    };
    let detail = wire::SessionDetail {
        session: summary,
        agents: Vec::new(),
        tasks: Vec::new(),
        signals: Vec::new(),
        observer: None,
        agent_activity: Vec::new(),
    };
    serde_json::to_string(&detail).expect("serialize fake session detail")
}

fn read_request(stream: &mut std::net::TcpStream) -> String {
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
        .expect("read timeout");
    let mut buffer = Vec::new();
    loop {
        let mut chunk = [0_u8; 1024];
        let read = stream.read(&mut chunk).expect("read request");
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    String::from_utf8_lossy(&buffer).into_owned()
}

fn write_response(stream: &mut std::net::TcpStream, body: &str) {
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .expect("write response");
    stream.flush().expect("flush response");
}

/// Outside a tokio runtime, `leave_session` reaches a live daemon exactly the
/// way it did through the root facade: it dials the fake daemon and returns
/// successfully off its response instead of touching local storage.
#[test]
fn leave_session_outside_a_tokio_runtime_uses_the_fake_daemon() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let session_id = "00000000-0000-4002-8000-0000000000b1";
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let token = "fake-daemon-token";
        let _lock = install_fake_running_xdg_daemon(tmp.path(), &endpoint, token);

        let response_body = fake_session_detail(session_id);
        let expected_path = format!("POST /v1/sessions/{session_id}/leave ");
        let server = std::thread::spawn(move || {
            loop {
                let (mut stream, _) = listener.accept().expect("accept");
                let request = read_request(&mut stream);
                let first_line = request.lines().next().unwrap_or_default();
                if first_line.starts_with("GET /v1/health") {
                    write_response(&mut stream, "ok");
                    continue;
                }
                if first_line.starts_with("GET /v1/ready") {
                    write_response(&mut stream, "{\"ready\":true,\"daemon_epoch\":\"t\"}");
                    continue;
                }
                assert!(
                    first_line.starts_with(&expected_path),
                    "expected {expected_path:?}, got: {first_line}"
                );
                write_response(&mut stream, &response_body);
                return;
            }
        });

        // No local session exists at all - the only way this can succeed is
        // by round-tripping through the fake daemon above.
        leave_session(session_id, "agent-1", tmp.path()).expect("leave via fake daemon");
        server.join().expect("server thread");
    });
}

/// Inside a tokio runtime, the guard must stop `leave_session` from ever
/// reaching the same fake daemon the previous test proved it reaches
/// otherwise: the daemon calls this function directly from its own async
/// worker threads, and a blocking self-call there would hold a worker open
/// for nothing.
#[test]
fn leave_session_inside_a_tokio_runtime_skips_the_daemon_round_trip() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let project = tmp.path().join("project");
        std::fs::create_dir_all(&project).expect("project dir");

        let session_id = "00000000-0000-4002-8000-0000000000b2";
        let state = temp_env::with_var("CLAUDE_SESSION_ID", Some("reentrancy-leader"), || {
            start_active_session("goal", "T", &project, Some("claude"), Some(session_id))
                .expect("start")
        });
        let leader_id = state.leader_id.expect("leader id");
        let joined = temp_env::with_var("CODEX_SESSION_ID", Some("reentrancy-worker"), || {
            join_session(
                session_id,
                SessionRole::Worker,
                "codex",
                &[],
                None,
                &project,
                None,
            )
            .expect("join")
        });
        let worker_id = joined
            .agents
            .keys()
            .find(|id| id.starts_with("codex-"))
            .expect("worker id")
            .clone();

        // A real, fully responsive fake daemon: if the guard were missing,
        // `leave_session` would dial it and this test would still pass, which
        // is exactly why the companion test above proves the daemon is
        // actually reachable when nothing suppresses the connection attempt.
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let token = "fake-daemon-token";
        let _lock = install_fake_running_xdg_daemon(tmp.path(), &endpoint, token);
        listener
            .set_nonblocking(true)
            .expect("nonblocking listener");

        let runtime = tokio::runtime::Runtime::new().expect("tokio runtime");
        runtime.block_on(async {
            leave_session(session_id, &worker_id, &project).expect("leave inside runtime");
        });

        match listener.accept() {
            Err(ref error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            other => panic!(
                "leave_session must not contact the daemon from a tokio runtime, got {other:?}"
            ),
        }

        let updated = session_status(session_id, &project).expect("status after leave");
        let agent = updated
            .agents
            .get(&worker_id)
            .expect("worker still recorded");
        assert!(
            !agent.status.is_alive(),
            "leave_session must still take effect locally when guarded"
        );
        let _ = leader_id;
    });
}
