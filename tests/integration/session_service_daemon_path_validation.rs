//! Proves the daemon-routed request-path builders inside `session::service`
//! reject an unsafe session, agent, or task id before any request reaches
//! the daemon, the same way `session::transport::task_daemon_routing_tests`
//! already proves it for the CLI layer.
//!
//! Each covered function checks for a live daemon before it ever touches
//! local storage, so a fully-responsive fake daemon that never sees the
//! mutating request is proof the rejection happened at the validation call,
//! not by some other path failing first.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use harness::daemon::client::test_support::install_fake_running_xdg_daemon;
use harness::session::service::{
    assign_role, join_session_with_fallback, record_task_checkpoint,
    register_agent_runtime_session, session_status,
};
use harness::session::types::SessionRole;
use harness_testkit::with_isolated_harness_env;

fn read_request(stream: &mut TcpStream) -> String {
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

fn write_response(stream: &mut TcpStream, body: &str) {
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .expect("write response");
    stream.flush().expect("flush response");
}

fn request_fake_daemon_shutdown(endpoint: &str) {
    let addr = endpoint.trim_start_matches("http://");
    if let Ok(mut stream) = TcpStream::connect(addr) {
        let _ = stream.write_all(
            b"GET /v1/test-shutdown HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n",
        );
        let _ = stream.flush();
    }
}

/// Runs `action` against a fake, fully-responsive daemon and asserts it
/// never received anything past the health/ready handshake: an unvalidated
/// id would otherwise reach the daemon as a malformed path instead of being
/// rejected up front.
fn assert_rejected_before_any_request_reaches_daemon<F>(action: F)
where
    F: FnOnce(),
{
    let tmp = tempfile::tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let token = "fake-daemon-token";
        let _lock = install_fake_running_xdg_daemon(tmp.path(), &endpoint, token);

        let captured: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let captured_inner = Arc::clone(&captured);
        let handle = thread::spawn(move || {
            loop {
                let Ok((mut stream, _)) = listener.accept() else {
                    return;
                };
                let request = read_request(&mut stream);
                let first_line = request.lines().next().unwrap_or_default().to_string();
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
                *captured_inner.lock().expect("lock") = Some(first_line);
                write_response(&mut stream, "{}");
                return;
            }
        });

        action();

        request_fake_daemon_shutdown(&endpoint);
        handle
            .join()
            .expect("fake daemon thread should exit cleanly after a shutdown request");
        let slot = captured.lock().expect("lock");
        assert!(
            slot.is_none(),
            "an id with a path separator or '..' must be rejected before any request is sent, \
             but the daemon captured {:?}",
            slot.as_ref()
        );
    });
}

#[test]
fn session_status_rejects_a_session_id_that_would_escape_its_path_segment() {
    assert_rejected_before_any_request_reaches_daemon(|| {
        let tmp = tempfile::tempdir().expect("project tempdir");
        let project = tmp.path().join("project");
        let error = session_status("../orchestrator/stop", &project).expect_err(
            "a session id with a path separator must be rejected before any request is sent",
        );
        assert!(error.to_string().contains("../orchestrator/stop"));
    });
}

#[test]
fn join_session_with_fallback_rejects_a_session_id_that_would_escape_its_path_segment() {
    assert_rejected_before_any_request_reaches_daemon(|| {
        let tmp = tempfile::tempdir().expect("project tempdir");
        let project = tmp.path().join("project");
        let error = join_session_with_fallback(
            "../orchestrator/stop",
            SessionRole::Worker,
            None,
            "claude",
            &[],
            None,
            &project,
            None,
        )
        .expect_err(
            "a session id with a path separator must be rejected before any request is sent",
        );
        assert!(error.to_string().contains("../orchestrator/stop"));
    });
}

#[test]
fn assign_role_rejects_an_agent_id_that_would_escape_its_path_segment() {
    assert_rejected_before_any_request_reaches_daemon(|| {
        let tmp = tempfile::tempdir().expect("project tempdir");
        let project = tmp.path().join("project");
        let error = assign_role(
            "00000000-0000-4000-8000-00000000c001",
            "../orchestrator/stop",
            SessionRole::Leader,
            None,
            "actor-1",
            &project,
        )
        .expect_err(
            "an agent id with a path separator must be rejected before any request is sent",
        );
        assert!(error.to_string().contains("../orchestrator/stop"));
    });
}

#[test]
fn record_task_checkpoint_rejects_a_task_id_that_would_escape_its_path_segment() {
    assert_rejected_before_any_request_reaches_daemon(|| {
        let tmp = tempfile::tempdir().expect("project tempdir");
        let project = tmp.path().join("project");
        let error = record_task_checkpoint(
            "00000000-0000-4000-8000-00000000c002",
            "foo/../bar",
            "actor-1",
            "halfway",
            50,
            &project,
        )
        .expect_err("a task id with a path separator must be rejected before any request is sent");
        assert!(error.to_string().contains("foo/../bar"));
    });
}

#[test]
fn register_agent_runtime_session_rejects_a_session_id_that_would_escape_its_path_segment() {
    assert_rejected_before_any_request_reaches_daemon(|| {
        let tmp = tempfile::tempdir().expect("project tempdir");
        let project = tmp.path().join("project");
        let error = register_agent_runtime_session(
            "../orchestrator/stop",
            "claude",
            "managed-1",
            "runtime-session-1",
            &project,
        )
        .expect_err(
            "a session id with a path separator must be rejected before any request is sent",
        );
        assert!(error.to_string().contains("../orchestrator/stop"));
    });
}
