use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::thread;

use super::DaemonClient;
use super::test_support::{read_http_request, write_http_response};
use crate::daemon::protocol::{
    PolicyTransferBundle, PolicyTransferDumpRequest, PolicyTransferImportRequest,
    TaskBoardAutomationHistoryRequest, TaskBoardListItemsRequest, TaskBoardUpdateItemRequest,
};
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
fn task_board_capability_preserves_non_missing_endpoint_errors() {
    let (endpoint, _request_line, handle) =
        spawn_mock("500 Internal Server Error", "backend unavailable".into());

    let error = client_with(endpoint)
        .require_database_task_board()
        .expect_err("daemon failure must remain diagnosable");
    handle.join().expect("server");
    assert!(error.to_string().contains("daemon HTTP 500"));
    assert!(!error.to_string().contains("upgrade and restart the daemon"));
}

#[test]
fn non_database_task_board_capability_reports_upgrade_required() {
    let (endpoint, _request_line, handle) = spawn_mock(
        "200 OK",
        r#"{"storage":"files","revision":42,"instance_id":"legacy-1"}"#.into(),
    );

    let error = client_with(endpoint)
        .require_database_task_board()
        .expect_err("file-backed capability must fail closed");
    handle.join().expect("server");
    assert!(error.to_string().contains("upgrade and restart the daemon"));
}

#[test]
fn invalid_task_board_capability_preserves_decode_error() {
    let (endpoint, _request_line, handle) = spawn_mock("200 OK", "{}".into());

    let error = client_with(endpoint)
        .require_database_task_board()
        .expect_err("invalid capability must remain diagnosable");
    handle.join().expect("server");
    assert!(error.to_string().contains("daemon HTTP parse response"));
    assert!(!error.to_string().contains("upgrade and restart the daemon"));
}

#[test]
fn task_board_list_serializes_status_as_query() {
    let response = serde_json::json!({ "items": [item()] }).to_string();
    let (endpoint, request_line, handle) = spawn_mock("200 OK", response);

    let items = client_with(endpoint)
        .list_task_board_items(&TaskBoardListItemsRequest {
            status: Some(TaskBoardStatus::Backlog),
        })
        .expect("list items");
    handle.join().expect("server");

    assert_eq!(items.len(), 1);
    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/items?status=backlog HTTP/1.1"
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

#[test]
fn automation_runs_encode_history_query() {
    let (endpoint, request_line, handle) =
        spawn_mock("200 OK", r#"{"runs":[],"has_older":false}"#.into());

    let response = client_with(endpoint)
        .task_board_automation_runs(&TaskBoardAutomationHistoryRequest {
            limit: Some(25),
            before: Some("2026-07-17T08:30:00Z/run 7".into()),
        })
        .expect("automation runs");
    handle.join().expect("server");

    assert!(response.runs.is_empty());
    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/orchestrator/runs?limit=25&before=2026-07-17T08%3A30%3A00Z%2Frun+7 HTTP/1.1"
    );
}

#[test]
fn triage_current_uses_item_triage_route() {
    let (endpoint, request_line, handle) = spawn_mock("200 OK", r#"{"current":null}"#.into());

    let response = client_with(endpoint)
        .get_task_board_item_triage("task-1")
        .expect("triage current");
    handle.join().expect("server");

    assert!(response.current.is_none());
    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/items/task-1/triage HTTP/1.1"
    );
}

#[test]
fn triage_history_encodes_cursor_and_limit_query() {
    let (endpoint, request_line, handle) = spawn_mock("200 OK", r#"{"decisions":[]}"#.into());

    let response = client_with(endpoint)
        .get_task_board_item_triage_history("task-1", Some(7), Some(25))
        .expect("triage history");
    handle.join().expect("server");

    assert!(response.decisions.is_empty());
    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/items/task-1/triage/history?before_generation=7&limit=25 HTTP/1.1"
    );
}

#[test]
fn triage_reads_reject_unsafe_item_ids_before_transport() {
    let client = client_with("http://127.0.0.1:1".to_string());

    let current = client
        .get_task_board_item_triage("../unsafe")
        .expect_err("unsafe current id");
    let history = client
        .get_task_board_item_triage_history("../unsafe", None, None)
        .expect_err("unsafe history id");

    assert_eq!(current.code(), "KSRCLI059");
    assert_eq!(history.code(), "KSRCLI059");
}

#[test]
fn automation_run_detail_expands_path_and_preserves_missing_detail_error() {
    let (endpoint, request_line, handle) =
        spawn_mock("400 Bad Request", r#"{"error":"not found"}"#.into());

    let error = client_with(endpoint)
        .task_board_automation_run_detail("run/42 ?#%")
        .expect_err("missing automation run");
    handle.join().expect("server");

    assert!(error.to_string().contains("HTTP 400"));
    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/orchestrator/runs/run%2F42%20%3F%23%25 HTTP/1.1"
    );
}

#[test]
fn automation_metrics_use_metrics_route() {
    let (endpoint, request_line, handle) = spawn_mock(
        "200 OK",
        r#"{"runs_total":3,"runs_running":1,"runs_completed":1,"runs_noop":0,"runs_partial":0,"runs_failed":1,"runs_cancelled":0,"open_conflicts":2,"captured_at":"2026-07-17T08:30:00Z"}"#.into(),
    );

    let response = client_with(endpoint)
        .task_board_automation_metrics()
        .expect("automation metrics");
    handle.join().expect("server");

    assert_eq!(response.runs_total, 3);
    assert_eq!(response.open_conflicts, 2);
    assert_eq!(
        *request_line.lock().expect("request line"),
        "GET /v1/task-board/orchestrator/metrics HTTP/1.1"
    );
}

#[test]
fn policy_transfer_dump_uses_bulk_post_route() {
    let (endpoint, request_line, handle) = spawn_mock(
        "200 OK",
        r#"{"format":"harness-policy-transfer","version":1,"policies":[],"workspace":null}"#.into(),
    );

    let bundle = client_with(endpoint)
        .dump_policy_transfer(&PolicyTransferDumpRequest {
            policy_ids: vec!["canvas-a".into(), "canvas-b".into()],
        })
        .expect("dump policy transfer");
    handle.join().expect("server");

    assert_eq!(bundle.format, "harness-policy-transfer");
    assert_eq!(bundle.version, 1);
    assert_eq!(
        *request_line.lock().expect("request line"),
        "POST /v1/policies/dump HTTP/1.1"
    );
}

#[test]
fn policy_transfer_import_uses_batch_route() {
    let (endpoint, request_line, handle) = spawn_mock(
        "200 OK",
        r#"{"schema_version":1,"active_canvas_id":"","canvases":[]}"#.into(),
    );
    let request = PolicyTransferImportRequest {
        bundle: PolicyTransferBundle {
            format: "harness-policy-transfer".into(),
            version: 1,
            policies: Vec::new(),
            workspace: None,
        },
        replace_all: false,
    };

    let workspace = client_with(endpoint)
        .import_policy_transfer(&request)
        .expect("import policy transfer");
    handle.join().expect("server");

    assert!(workspace.canvases.is_empty());
    assert_eq!(
        *request_line.lock().expect("request line"),
        "POST /v1/policies/import HTTP/1.1"
    );
}
