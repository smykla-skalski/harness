use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;

use super::DaemonClient;
use super::test_support::{read_http_request, write_http_response};
use crate::daemon::protocol::{TaskBoardListItemsRequest, TaskBoardUpdateItemRequest};
use crate::task_board::{TaskBoardItem, TaskBoardStatus};

fn client_with(endpoint: String) -> DaemonClient {
    DaemonClient {
        endpoint,
        token: "test-token".into(),
        http: reqwest::Client::new(),
    }
}

fn spawn_mock(
    response_status: &'static str,
    response_body: String,
) -> (String, Arc<Mutex<String>>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let request_line = Arc::new(Mutex::new(String::new()));
    let captured = Arc::clone(&request_line);
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let request = read_http_request(&mut stream);
        *captured.lock().expect("request capture") =
            request.lines().next().unwrap_or_default().to_string();
        write_http_response(
            &mut stream,
            response_status,
            "application/json",
            &response_body,
        );
    });
    (endpoint, request_line, handle)
}

fn item() -> TaskBoardItem {
    TaskBoardItem::new(
        "task-1".into(),
        "Database task".into(),
        "body".into(),
        "2026-07-11T00:00:00Z".into(),
    )
}

#[test]
fn task_board_capability_requires_database_storage_and_returns_revision() {
    let (endpoint, request_line, handle) = spawn_mock(
        "200 OK",
        r#"{"storage":"database","revision":42,"instance_id":"database-1"}"#.into(),
    );

    assert_eq!(
        client_with(endpoint)
            .require_database_task_board()
            .expect("database capability"),
        42
    );
    handle.join().expect("server");
    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/capabilities HTTP/1.1"
    );
}

#[test]
fn missing_task_board_capability_reports_upgrade_required() {
    let (endpoint, _request_line, handle) =
        spawn_mock("404 Not Found", r#"{"error":"not found"}"#.into());

    let error = client_with(endpoint)
        .require_database_task_board()
        .expect_err("missing capability must fail closed");
    handle.join().expect("server");
    assert!(error.to_string().contains("upgrade and restart the daemon"));
}

#[test]
fn non_database_task_board_capability_reports_upgrade_required() {
    let (endpoint, _request_line, handle) =
        spawn_mock("200 OK", r#"{"storage":"files","revision":42}"#.into());

    let error = client_with(endpoint)
        .require_database_task_board()
        .expect_err("file-backed capability must fail closed");
    handle.join().expect("server");
    assert!(error.to_string().contains("upgrade and restart the daemon"));
}

#[test]
fn invalid_task_board_capability_reports_upgrade_required() {
    let (endpoint, _request_line, handle) = spawn_mock("200 OK", "{}".into());

    let error = client_with(endpoint)
        .require_database_task_board()
        .expect_err("invalid capability must fail closed");
    handle.join().expect("server");
    assert!(error.to_string().contains("upgrade and restart the daemon"));
}

#[test]
fn task_board_list_serializes_status_as_query() {
    let response = serde_json::json!({ "items": [item()] }).to_string();
    let (endpoint, request_line, handle) = spawn_mock("200 OK", response);

    let items = client_with(endpoint)
        .list_task_board_items(&TaskBoardListItemsRequest {
            status: Some(TaskBoardStatus::Todo),
        })
        .expect("list items");
    handle.join().expect("server");

    assert_eq!(items.len(), 1);
    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/items?status=todo HTTP/1.1"
    );
}

#[test]
fn task_board_update_uses_put_item_route() {
    let (endpoint, request_line, handle) =
        spawn_mock("200 OK", serde_json::to_string(&item()).expect("item JSON"));

    let updated = client_with(endpoint)
        .update_task_board_item(
            "task-1",
            &TaskBoardUpdateItemRequest {
                title: Some("Updated".into()),
                ..TaskBoardUpdateItemRequest::default()
            },
        )
        .expect("update item");
    handle.join().expect("server");

    assert_eq!(updated.id, "task-1");
    assert_eq!(
        *request_line.lock().expect("request line"),
        "PUT /v1/task-board/items/task-1 HTTP/1.1"
    );
}
