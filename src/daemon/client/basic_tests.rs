use std::net::TcpListener;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;

use super::DaemonClient;
use super::connection::{
    daemon_client_allowed_in_current_context, try_build_client, wait_for_authenticated_api,
};
use super::http::parse_error_response;
use super::test_support::{read_http_request, write_http_response};

#[test]
fn try_connect_returns_none_when_no_daemon() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    std::fs::create_dir_all(&home).expect("create home");
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8"))),
            ("HOME", Some(home.to_str().expect("utf8 home"))),
            ("HARNESS_HOST_HOME", Some(home.to_str().expect("utf8 home"))),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_DAEMON_DATA_HOME", None),
        ],
        || {
            let client = try_build_client();
            assert!(client.is_none());
        },
    );
}

#[test]
fn parse_error_response_extracts_message() {
    let body = r#"{"error":{"code":"KSRCLI092","message":"agent conflict"}}"#;
    let error = parse_error_response(body, 400);
    assert!(error.to_string().contains("agent conflict"));
}

#[test]
fn parse_error_response_handles_plain_text() {
    let error = parse_error_response("not json", 500);
    assert!(error.to_string().contains("500"));
}

#[test]
fn wait_for_authenticated_api_retries_until_sessions_endpoint_succeeds() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let saw_auth = Arc::new(AtomicBool::new(false));
    let session_calls = Arc::new(AtomicUsize::new(0));

    let server = {
        let saw_auth = Arc::clone(&saw_auth);
        let session_calls = Arc::clone(&session_calls);
        thread::spawn(move || {
            for _ in 0..2 {
                let (mut stream, _) = listener.accept().expect("accept");
                let request = read_http_request(&mut stream);
                if request
                    .to_ascii_lowercase()
                    .contains("authorization: bearer test-token")
                {
                    saw_auth.store(true, Ordering::SeqCst);
                }
                let call_index = session_calls.fetch_add(1, Ordering::SeqCst);
                if call_index == 0 {
                    write_http_response(
                        &mut stream,
                        "503 Service Unavailable",
                        "application/json",
                        "{\"error\":\"warming up\"}",
                    );
                } else {
                    write_http_response(&mut stream, "200 OK", "application/json", "[]");
                }
            }
        })
    };

    let client = DaemonClient {
        endpoint,
        token: "test-token".to_string(),
        http: reqwest::Client::new(),
    };
    assert!(wait_for_authenticated_api(
        &client,
        Duration::from_millis(250)
    ));
    assert!(saw_auth.load(Ordering::SeqCst));
    assert_eq!(session_calls.load(Ordering::SeqCst), 2);
    server.join().expect("server");
}

#[test]
fn wait_for_authenticated_api_returns_false_when_sessions_endpoint_never_recovers() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let session_calls = Arc::new(AtomicUsize::new(0));

    let server = {
        let session_calls = Arc::clone(&session_calls);
        thread::spawn(move || {
            for _ in 0..3 {
                let (mut stream, _) = listener.accept().expect("accept");
                let _request = read_http_request(&mut stream);
                session_calls.fetch_add(1, Ordering::SeqCst);
                write_http_response(
                    &mut stream,
                    "503 Service Unavailable",
                    "application/json",
                    "{\"error\":\"still warming up\"}",
                );
            }
        })
    };

    let client = DaemonClient {
        endpoint,
        token: "test-token".to_string(),
        http: reqwest::Client::new(),
    };
    assert!(!wait_for_authenticated_api(
        &client,
        Duration::from_millis(250)
    ));
    assert!(session_calls.load(Ordering::SeqCst) >= 2);
    server.join().expect("server");
}

#[test]
fn daemon_client_allowed_in_current_context_rejects_active_tokio_runtime() {
    assert!(daemon_client_allowed_in_current_context());

    let runtime = tokio::runtime::Runtime::new().expect("runtime");
    runtime.block_on(async {
        assert!(!daemon_client_allowed_in_current_context());
    });
}
