use super::*;

use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;

use crate::daemon::client::test_support::{
    install_fake_running_xdg_daemon, read_http_request, write_http_response,
};

#[test]
fn start_session_direct_without_db_forwards_policy_preset_to_daemon_client() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let requests = Arc::new(Mutex::new(Vec::<String>::new()));
        let requests_for_server = Arc::clone(&requests);
        let token = "direct-start-token";
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
                    request.starts_with("POST /v1/sessions "),
                    "expected session start POST, got: {request}"
                );
                requests_for_server
                    .lock()
                    .expect("request capture")
                    .push(request.clone());
                let state = crate::session::service::build_new_session_with_policy(
                    "daemon forwarded context",
                    "daemon forwarded title",
                    "daemon-forwarded-session",
                    "claude",
                    Some("leader-session"),
                    &utc_now(),
                    Some("swarm-default"),
                );
                let body = serde_json::to_string(
                    &crate::daemon::protocol::SessionMutationResponse { state },
                )
                .expect("serialize response");
                write_http_response(&mut stream, "200 OK", "application/json", &body);
            }
        });

        let project = tmp.path().join("project");
        std::fs::create_dir_all(&project).expect("create project");
        let state = start_session_direct(
            &crate::daemon::protocol::SessionStartRequest {
                title: "direct daemon fallback".into(),
                context: "daemon client fallback".into(),
                runtime: "claude".into(),
                session_id: Some("daemon-client-start".into()),
                project_dir: project.to_string_lossy().into_owned(),
                policy_preset: Some("swarm-default".into()),
            },
            None,
        )
        .expect("start session through daemon client");

        assert_eq!(state.session_id, "daemon-forwarded-session");

        server.join().expect("server");
        let request = requests
            .lock()
            .expect("request capture")
            .pop()
            .expect("captured post request");
        assert!(
            request.contains("\"policy_preset\":\"swarm-default\""),
            "policy_preset must be forwarded in daemon request body: {request}"
        );
    });
}
