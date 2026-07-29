use std::io::{ErrorKind, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::json;
use tempfile::tempdir;

use harness::daemon::state::test_support::install_fake_running_xdg_daemon;
use harness::session::service::{self, build_new_session_with_policy};
use harness::session::transport::{SessionObserveArgs, SessionTitleArgs};
use harness::session::types::SessionState;
use harness::session::wire::SessionMutationResponse;
use harness::workspace::utc_now;
use harness_testkit::{init_git_repo_with_seed, with_isolated_harness_env};
use harness_workspace::command_context::{AppContext, Execute};

// `harness::daemon::state::test_support`'s own `read_http_request`/
// `write_http_response` stay `#[cfg(test)]`-gated to the root crate's own
// unit tests; this scenario runs from `tests/integration_daemon.rs` instead,
// so it carries its own copies, matching every other daemon-fixture test
// relocated out of `session::transport`.
fn read_http_request(stream: &mut TcpStream) -> String {
    stream.set_nonblocking(false).expect("blocking stream");
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .expect("read timeout");
    // The per-read timeout above bounds a single `read()` call; this
    // deadline bounds the whole request, since completing the body now
    // takes another read past the one that lands the headers, and a
    // timed-out individual read (a slow write under load, not a dead
    // peer) should retry rather than fail the test outright.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut buffer = Vec::new();
    let mut headers_done = false;
    let mut content_length = 0_usize;
    let mut header_end = 0_usize;
    loop {
        let mut chunk = [0_u8; 1024];
        let read = match stream.read(&mut chunk) {
            Ok(read) => read,
            Err(error)
                if matches!(error.kind(), ErrorKind::TimedOut | ErrorKind::WouldBlock)
                    && Instant::now() < deadline =>
            {
                continue;
            }
            Err(error) => panic!("read request: {error}"),
        };
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
    String::from_utf8(buffer).expect("utf8 request")
}

fn write_http_response(stream: &mut TcpStream, status: &str, content_type: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .expect("write response");
    stream.flush().expect("flush response");
}

#[test]
fn session_title_execute_updates_active_session_via_daemon_client() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let requests = Arc::new(Mutex::new(Vec::<String>::new()));
        let requests_for_server = Arc::clone(&requests);
        let token = "session-title-token";
        let token_lower = token.to_ascii_lowercase();
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let _lock_file = install_fake_running_xdg_daemon(tmp.path(), &endpoint, token);
        let server = thread::spawn(move || {
            for _ in 0..3 {
                let (mut stream, _) = listener.accept().expect("accept");
                let request = read_http_request(&mut stream);
                let request_lower = request.to_ascii_lowercase();
                assert!(
                    request_lower.contains(&format!("authorization: bearer {token_lower}")),
                    "missing bearer auth: {request}"
                );
                if request.starts_with("GET /v1/health ") {
                    write_http_response(&mut stream, "200 OK", "text/plain", "ok");
                    continue;
                }
                if request.starts_with("GET /v1/ready ") {
                    write_http_response(
                        &mut stream,
                        "200 OK",
                        "application/json",
                        "{\"ready\":true,\"daemon_epoch\":\"test\"}",
                    );
                    continue;
                }
                if request.starts_with("GET /v1/sessions ") {
                    write_http_response(&mut stream, "200 OK", "application/json", "[]");
                    continue;
                }
                assert!(
                    request.starts_with(
                        "POST /v1/sessions/00000000-0000-4000-8000-00000000b001/title "
                    ),
                    "expected session title POST, got: {request}"
                );
                requests_for_server
                    .lock()
                    .expect("request capture")
                    .push(request.clone());
                let body = serde_json::to_string(&SessionMutationResponse {
                    state: build_new_session_with_policy(
                        "daemon title context",
                        "renamed title",
                        "00000000-0000-4000-8000-00000000b001",
                        "leaderless",
                        None,
                        &utc_now(),
                        None,
                    ),
                })
                .expect("serialize response");
                write_http_response(&mut stream, "200 OK", "application/json", &body);
            }
        });

        let project = tmp.path().join("project");
        init_git_repo_with_seed(&project);

        let exit = SessionTitleArgs {
            session_id: "00000000-0000-4000-8000-00000000b001".into(),
            title: "renamed title".into(),
            project_dir: Some(project.to_string_lossy().into_owned()),
        }
        .execute(&AppContext)
        .expect("session title should route through daemon");

        assert_eq!(exit, 0);

        server.join().expect("server");
        let request = requests
            .lock()
            .expect("request capture")
            .pop()
            .expect("captured title request");
        assert!(
            request.contains("\"title\":\"renamed title\""),
            "title must be forwarded in daemon request body: {request}"
        );
    });
}

fn session_observe_detail_response(state: &SessionState) -> String {
    json!({
        "session": {
            "project_id": "p",
            "project_name": state.project_name,
            "project_dir": null,
            "context_root": "/",
            "worktree_path": "/",
            "shared_path": "/",
            "origin_path": "/",
            "branch_ref": state.branch_ref,
            "session_id": state.session_id,
            "title": state.title,
            "context": state.context,
            "status": "awaiting_leader",
            "created_at": state.created_at,
            "updated_at": state.updated_at,
            "last_activity_at": null,
            "leader_id": null,
            "observe_id": state.observe_id,
            "pending_leader_transfer": null,
            "metrics": {}
        },
        "agents": [],
        "tasks": [],
        "signals": [],
        "observer": null,
        "agent_activity": []
    })
    .to_string()
}

#[test]
fn session_observe_execute_routes_actorful_one_shot_via_daemon_client() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let project = tmp.path().join("project");
        init_git_repo_with_seed(&project);
        let state = service::start_session_with_policy(
            "daemon observe context",
            "",
            &project,
            Some("53760875-91e8-5c4e-afce-ac4dcf1390a5"),
            None,
        )
        .expect("start session");
        let response_body = session_observe_detail_response(&state);

        let requests = Arc::new(Mutex::new(Vec::<String>::new()));
        let requests_for_server = Arc::clone(&requests);
        let running = Arc::new(AtomicBool::new(true));
        let running_for_server = Arc::clone(&running);
        let token = "session-observe-token";
        let token_lower = token.to_ascii_lowercase();
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        listener
            .set_nonblocking(true)
            .expect("nonblocking listener");
        let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
        let _lock_file = install_fake_running_xdg_daemon(tmp.path(), &endpoint, token);
        let server = thread::spawn(move || {
            while running_for_server.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let request = read_http_request(&mut stream);
                        let request_lower = request.to_ascii_lowercase();
                        assert!(
                            request_lower.contains(&format!("authorization: bearer {token_lower}")),
                            "missing bearer auth: {request}"
                        );
                        if request.starts_with("GET /v1/health ") {
                            write_http_response(&mut stream, "200 OK", "text/plain", "ok");
                            continue;
                        }
                        if request.starts_with("GET /v1/ready ") {
                            write_http_response(
                                &mut stream,
                                "200 OK",
                                "application/json",
                                "{\"ready\":true,\"daemon_epoch\":\"test\"}",
                            );
                            continue;
                        }
                        if request
                            .starts_with("GET /v1/sessions/53760875-91e8-5c4e-afce-ac4dcf1390a5 ")
                        {
                            write_http_response(
                                &mut stream,
                                "200 OK",
                                "application/json",
                                &response_body,
                            );
                            requests_for_server
                                .lock()
                                .expect("request capture")
                                .push(request);
                            continue;
                        }
                        if request.starts_with(
                            "POST /v1/sessions/53760875-91e8-5c4e-afce-ac4dcf1390a5/observe ",
                        ) {
                            write_http_response(
                                &mut stream,
                                "200 OK",
                                "application/json",
                                &response_body,
                            );
                            requests_for_server
                                .lock()
                                .expect("request capture")
                                .push(request);
                            continue;
                        }
                        panic!("unexpected request: {request}");
                    }
                    Err(error) if error.kind() == ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("accept failed: {error}"),
                }
            }
        });

        let exit = SessionObserveArgs {
            session_id: "53760875-91e8-5c4e-afce-ac4dcf1390a5".into(),
            poll_interval: 0,
            json: true,
            actor: Some("observer-1".into()),
            project_dir: Some(project.to_string_lossy().into_owned()),
        }
        .execute(&AppContext)
        .expect("session observe should route through daemon");

        assert_eq!(exit, 0);

        running.store(false, Ordering::SeqCst);
        server.join().expect("server");

        let requests = requests.lock().expect("request capture");
        let observe_request = requests
            .iter()
            .find(|request| {
                request
                    .starts_with("POST /v1/sessions/53760875-91e8-5c4e-afce-ac4dcf1390a5/observe ")
            })
            .expect("captured observe request");
        assert!(
            observe_request.contains("\"actor\":\"observer-1\""),
            "observe actor must be forwarded in daemon request body: {observe_request}"
        );
    });
}

#[test]
fn session_observe_rejects_a_session_id_that_would_escape_its_path_segment() {
    let args = SessionObserveArgs {
        session_id: "../orchestrator/stop".into(),
        poll_interval: 0,
        json: true,
        actor: Some("observer-1".into()),
        project_dir: None,
    };
    let error = args
        .execute(&AppContext)
        .expect_err("a session id with a path separator must be rejected before any request");
    assert!(error.to_string().contains("../orchestrator/stop"));
}
