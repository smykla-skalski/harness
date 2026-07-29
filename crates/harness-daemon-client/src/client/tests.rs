use std::io::{Read as _, Write as _};
use std::net::TcpListener;

use serde::Deserialize;

use super::*;

#[derive(Debug, Deserialize, PartialEq, Eq)]
struct Payload {
    value: String,
}

#[test]
fn get_optional_sends_bearer_auth_and_decodes_json() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("address"));
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let mut request = [0_u8; 2048];
        let size = stream.read(&mut request).expect("read request");
        let request = String::from_utf8_lossy(&request[..size]);
        assert!(request.starts_with("GET /v1/example?kind=hook HTTP/1.1"));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer secret")
        );
        stream
            .write_all(
                b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 14\r\n\r\n{\"value\":\"ok\"}",
            )
            .expect("write response");
    });

    let client = DaemonClient::test_client(endpoint, "secret");
    assert_eq!(
        client
            .get_optional("/v1/example", &[("kind", "hook")])
            .expect("get"),
        Some(Payload {
            value: "ok".to_string()
        })
    );
    server.join().expect("server");
}

#[derive(Debug, Serialize)]
struct UpdateRequest {
    value: String,
}

#[test]
fn put_sends_bearer_auth_and_json_body_and_decodes_response() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("address"));
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let mut request = [0_u8; 2048];
        let size = stream.read(&mut request).expect("read request");
        let request = String::from_utf8_lossy(&request[..size]);
        assert!(request.starts_with("PUT /v1/example HTTP/1.1"));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer secret")
        );
        assert!(request.contains("{\"value\":\"updated\"}"));
        stream
            .write_all(
                b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 14\r\n\r\n{\"value\":\"ok\"}",
            )
            .expect("write response");
    });

    let client = DaemonClient::test_client(endpoint, "secret");
    let request = UpdateRequest {
        value: "updated".to_string(),
    };
    assert_eq!(
        client
            .put::<UpdateRequest, Payload>("/v1/example", &request)
            .expect("put"),
        Payload {
            value: "ok".to_string()
        }
    );
    server.join().expect("server");
}

#[test]
fn delete_sends_bearer_auth_and_decodes_response() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("address"));
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let mut request = [0_u8; 2048];
        let size = stream.read(&mut request).expect("read request");
        let request = String::from_utf8_lossy(&request[..size]);
        assert!(request.starts_with("DELETE /v1/example HTTP/1.1"));
        assert!(
            request
                .to_ascii_lowercase()
                .contains("authorization: bearer secret")
        );
        stream
            .write_all(
                b"HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 14\r\n\r\n{\"value\":\"ok\"}",
            )
            .expect("write response");
    });

    let client = DaemonClient::test_client(endpoint, "secret");
    assert_eq!(
        client.delete::<Payload>("/v1/example").expect("delete"),
        Payload {
            value: "ok".to_string()
        }
    );
    server.join().expect("server");
}

#[test]
fn delete_decodes_a_204_with_empty_body_as_unit() {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("address"));
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let mut request = [0_u8; 2048];
        let size = stream.read(&mut request).expect("read request");
        let request = String::from_utf8_lossy(&request[..size]);
        assert!(request.starts_with("DELETE /v1/sessions/abc HTTP/1.1"));
        stream
            .write_all(b"HTTP/1.1 204 No Content\r\ncontent-length: 0\r\n\r\n")
            .expect("write response");
    });

    let client = DaemonClient::test_client(endpoint, "secret");
    client
        .delete::<()>("/v1/sessions/abc")
        .expect("204 with an empty body should decode as unit");
    server.join().expect("server");
}

#[test]
fn mutation_timeout_for_path_matches_known_long_running_routes() {
    assert_eq!(
        mutation_timeout_for_path("/v1/sessions"),
        SESSION_START_TIMEOUT
    );
    for path in [
        "/v1/task-board/sync",
        "/v1/task-board/dispatch",
        "/v1/task-board/dispatch/deliver",
        "/v1/task-board/evaluate",
        "/v1/task-board/orchestrator/run-once",
        "/v1/policies/dump",
        "/v1/policies/import",
    ] {
        assert_eq!(
            mutation_timeout_for_path(path),
            TASK_BOARD_OPERATION_TIMEOUT,
            "{path} should use the task-board operation timeout"
        );
    }
    assert_eq!(
        mutation_timeout_for_path("/v1/task-board/items"),
        REQUEST_TIMEOUT
    );
}

#[test]
fn response_display_message_parses_the_daemon_error_envelope() {
    let body = r#"{"error":{"code":"SESSION_NOT_ACTIVE","message":"session is not active"}}"#;
    assert_eq!(
        response_display_message("POST", "/v1/sessions/abc/end", 409, body),
        "daemon error (SESSION_NOT_ACTIVE, HTTP 409): session is not active"
    );
}

#[test]
fn response_display_message_falls_back_when_the_body_is_not_the_error_envelope() {
    let body = "not json";
    assert_eq!(
        response_display_message("POST", "/v1/sessions/abc/end", 500, body),
        "daemon HTTP POST /v1/sessions/abc/end returned 500: not json"
    );
}
