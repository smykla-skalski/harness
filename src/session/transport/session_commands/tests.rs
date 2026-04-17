use std::net::TcpListener;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::thread;

use tempfile::tempdir;

use super::*;
use crate::app::command_context::AppContext;
use crate::daemon::client::test_support::{
    install_fake_running_xdg_daemon, read_http_request, write_http_response,
};
use crate::session::service::build_new_session_with_policy;
use crate::workspace::utc_now;
use harness_testkit::with_isolated_harness_env;

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
                if request.starts_with("GET /v1/sessions ") {
                    write_http_response(&mut stream, "200 OK", "application/json", "[]");
                    continue;
                }
                assert!(
                    request.starts_with("POST /v1/sessions/sess-title-daemon/title "),
                    "expected session title POST, got: {request}"
                );
                requests_for_server
                    .lock()
                    .expect("request capture")
                    .push(request.clone());
                let body =
                    serde_json::to_string(&crate::daemon::protocol::SessionMutationResponse {
                        state: build_new_session_with_policy(
                            "daemon title context",
                            "renamed title",
                            "sess-title-daemon",
                            "claude",
                            Some("leader-session"),
                            &utc_now(),
                            None,
                        ),
                    })
                    .expect("serialize response");
                write_http_response(&mut stream, "200 OK", "application/json", &body);
            }
        });

        let project = tmp.path().join("project");
        std::fs::create_dir_all(&project).expect("create project");
        let status = Command::new("git")
            .arg("init")
            .arg("-q")
            .arg(&project)
            .status()
            .expect("git init");
        assert!(status.success(), "git init should succeed");

        let exit = SessionTitleArgs {
            session_id: "sess-title-daemon".into(),
            title: "renamed title".into(),
            project_dir: Some(project.to_string_lossy().into_owned()),
        }
        .execute(&AppContext::default())
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
