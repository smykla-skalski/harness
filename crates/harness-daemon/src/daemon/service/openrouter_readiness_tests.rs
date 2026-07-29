use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread::{self, JoinHandle};

use super::*;

fn block_on<F: std::future::Future>(future: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("build test runtime")
        .block_on(future)
}

fn serve_once(status: &str, body: &str) -> (String, JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind test server");
    let address = listener.local_addr().expect("test server address");
    let status = status.to_string();
    let body = body.to_string();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept request");
        let mut request = [0_u8; 4096];
        let count = stream.read(&mut request).expect("read request");
        let request = String::from_utf8_lossy(&request[..count]);
        assert!(
            request.starts_with("GET /models/user HTTP/1.1"),
            "unexpected request line: {request}"
        );
        assert!(
            request
                .lines()
                .any(|line| line.to_ascii_lowercase().starts_with("authorization: bearer")),
            "request omitted bearer authorization"
        );
        write!(
            stream,
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
        .expect("write response");
    });
    (format!("http://{address}"), server)
}

#[test]
fn accepted_key_with_offered_model_reports_available() {
    let (base_url, server) = serve_once(
        "200 OK",
        r#"{"data":[{"id":"deepseek/deepseek-v4-flash"},{"id":"openai/gpt-5.5"}]}"#,
    );
    let readiness = block_on(probe_at(&base_url, "or-secret", "deepseek/deepseek-v4-flash"));
    server.join().expect("mock server finishes");
    assert_eq!(readiness.credential, OpenRouterCredential::Accepted);
    assert_eq!(readiness.model_available, Some(true));
}

#[test]
fn accepted_key_without_offered_model_reports_unavailable() {
    let (base_url, server) = serve_once("200 OK", r#"{"data":[{"id":"openai/gpt-5.5"}]}"#);
    let readiness = block_on(probe_at(&base_url, "or-secret", "deepseek/deepseek-v4-flash"));
    server.join().expect("mock server finishes");
    assert_eq!(readiness.credential, OpenRouterCredential::Accepted);
    assert_eq!(readiness.model_available, Some(false));
}

#[test]
fn accepted_key_with_unreadable_body_leaves_model_undetermined() {
    // A 200 the deserializer cannot map to a model list (unknown envelope) must
    // not read as "model unavailable"; it leaves the decision to the caller's
    // static-catalog fallback via `None`.
    let (base_url, server) = serve_once("200 OK", r#"{"models":[{"id":"x"}]}"#);
    let readiness = block_on(probe_at(&base_url, "or-secret", "deepseek/deepseek-v4-flash"));
    server.join().expect("mock server finishes");
    assert_eq!(readiness.credential, OpenRouterCredential::Accepted);
    assert_eq!(readiness.model_available, None);
}

#[test]
fn rejected_key_reports_rejection_without_leaking_secret() {
    let (base_url, server) = serve_once("401 Unauthorized", "");
    let readiness = block_on(probe_at(&base_url, "or-secret-value", "any/model"));
    server.join().expect("mock server finishes");
    let OpenRouterCredential::Rejected(detail) = readiness.credential else {
        panic!("expected rejection, got {:?}", readiness.credential);
    };
    assert!(detail.contains("401"), "detail should name the status");
    assert!(!detail.contains("or-secret-value"));
    assert_eq!(readiness.model_available, None);
}

#[test]
fn payment_required_key_reports_rejection() {
    let (base_url, server) = serve_once("402 Payment Required", "");
    let readiness = block_on(probe_at(&base_url, "or-secret", "any/model"));
    server.join().expect("mock server finishes");
    assert!(matches!(
        readiness.credential,
        OpenRouterCredential::Rejected(_)
    ));
}

#[test]
fn server_error_leaves_credential_unverified() {
    let (base_url, server) = serve_once("503 Service Unavailable", "");
    let readiness = block_on(probe_at(&base_url, "or-secret", "any/model"));
    server.join().expect("mock server finishes");
    assert!(matches!(
        readiness.credential,
        OpenRouterCredential::Unverified(_)
    ));
    assert_eq!(readiness.model_available, None);
}

#[test]
fn unreachable_provider_leaves_credential_unverified() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind for port");
    let port = listener.local_addr().expect("addr").port();
    drop(listener);
    let base_url = format!("http://127.0.0.1:{port}");
    let readiness = block_on(probe_at(&base_url, "or-secret", "any/model"));
    assert!(matches!(
        readiness.credential,
        OpenRouterCredential::Unverified(_)
    ));
    assert_eq!(readiness.model_available, None);
}
