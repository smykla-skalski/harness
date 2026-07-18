use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::Value;

use super::*;

mod create_recovery_tests;
mod move_tests;
mod pagination_tests;
mod request_id_tests;
mod revision_tests;

#[derive(Debug, Default)]
struct CapturedRequest {
    method: String,
    path: String,
    authorization: Option<String>,
    request_id: Option<String>,
    body: String,
}

#[test]
fn todoist_production_base_uses_official_v1_api() {
    assert_eq!(TODOIST_API_BASE, "https://api.todoist.com/api/v1");
}

#[test]
fn todoist_capabilities_include_status_updates() {
    let client =
        TodoistSyncClient::new_with_api_base("token", "https://todoist.invalid").expect("client");

    assert!(
        client
            .capabilities()
            .supports_update(ExternalSyncField::Status)
    );
}

#[tokio::test]
async fn todoist_status_only_close_canonicalizes_missing_reference_url() {
    let (endpoint, captured, handle) = spawn_status_mock();
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let item = local_item_with_status(TaskBoardStatus::Done);

    let outcome = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Status]),
        )
        .await
        .expect("update task status");

    assert_status_update_reference(outcome);
    handle.join().expect("mock server");
    let captured = captured.lock().expect("captured request");
    assert_eq!(captured.path, "/tasks/remote-1/close");
    assert_eq!(captured.authorization.as_deref(), Some("Bearer token"));
    assert!(captured.body.is_empty());
}

#[tokio::test]
async fn todoist_status_only_reopen_replaces_legacy_reference_url() {
    let (endpoint, captured, handle) = spawn_status_mock();
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1")
        .with_url("https://legacy.todoist.invalid/task/remote-1");
    let item = local_item_with_status(TaskBoardStatus::InProgress);

    let outcome = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Status]),
        )
        .await
        .expect("update task status");

    assert_status_update_reference(outcome);
    handle.join().expect("mock server");
    let captured = captured.lock().expect("captured request");
    assert_eq!(captured.path, "/tasks/remote-1/reopen");
    assert_eq!(captured.authorization.as_deref(), Some("Bearer token"));
    assert!(captured.body.is_empty());
}

fn assert_status_update_reference(outcome: ExternalUpdateOutcome) {
    let ExternalUpdateOutcome::Applied {
        reference,
        provider_revision,
    } = outcome
    else {
        panic!("status update must be applied");
    };
    assert_eq!(
        reference.url.as_deref(),
        Some("https://app.todoist.com/app/task/remote-1")
    );
    assert_eq!(provider_revision, ExternalRevisionUpdate::Clear);
}

#[tokio::test]
async fn todoist_push_task_posts_metadata_payload() {
    let (endpoint, captured, handle) = spawn_json_mock(
        r#"{"id":"remote-1","content":"Remote title","description":"Remote body","project_id":"provider-project","updated_at":"provider-revision-1"}"#,
    );
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let item = local_item("Local title", "Local body", Some("project-1"));

    let outcome = client
        .push_task_with_outcome(&item)
        .await
        .expect("push task");

    assert_eq!(outcome.reference.external_id, "remote-1");
    assert_eq!(
        outcome.provider_revision.as_deref(),
        Some("provider-revision-1")
    );
    assert_eq!(
        outcome.provider_project_id.as_deref(),
        Some("provider-project")
    );
    assert_eq!(
        outcome.reference.url.as_deref(),
        Some("https://app.todoist.com/app/task/remote-1")
    );
    handle.join().expect("mock server");
    let captured = captured.lock().expect("captured request");
    assert_eq!(captured.path, "/tasks");
    assert_eq!(captured.authorization.as_deref(), Some("Bearer token"));
    let body = body_json(&captured.body);
    assert_eq!(body["content"], "Local title");
    assert_eq!(body["description"], "Local body");
    assert_eq!(body["project_id"], "project-1");
}

#[tokio::test]
async fn todoist_update_task_posts_changed_metadata_payload() {
    let (endpoint, captured, handle) = spawn_json_mock(
        r#"{"id":"remote-1","content":"Remote title","description":"Remote body","project_id":"project-2","updated_at":null}"#,
    );
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let item = local_item("Updated title", "Updated body", Some("project-2"));

    let outcome = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Title, ExternalSyncField::Body]),
        )
        .await
        .expect("update task metadata");

    let ExternalUpdateOutcome::Applied {
        reference,
        provider_revision,
    } = outcome
    else {
        panic!("metadata update must be applied");
    };
    assert_eq!(
        reference.url.as_deref(),
        Some("https://app.todoist.com/app/task/remote-1")
    );
    assert_eq!(provider_revision, ExternalRevisionUpdate::Clear);
    handle.join().expect("mock server");
    let captured = captured.lock().expect("captured request");
    assert_eq!(captured.path, "/tasks/remote-1");
    assert_eq!(captured.authorization.as_deref(), Some("Bearer token"));
    let body = body_json(&captured.body);
    assert_eq!(body["content"], "Updated title");
    assert_eq!(body["description"], "Updated body");
    assert!(body.get("project_id").is_none());
}

#[tokio::test]
async fn todoist_precondition_failure_returns_current_remote_snapshot() {
    let (endpoint, captured, handle) = spawn_json_mock_response(
        r#"{"id":"remote-1","content":"Remote edit","description":"Remote body","project_id":"project-1","updated_at":"provider-revision-2"}"#,
    );
    let client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1");
    let item = local_item("Local edit", "Local body", Some("project-1"));

    let outcome = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Title])
                .with_precondition_updated_at(Some("provider-revision-1".into())),
        )
        .await
        .expect("check precondition");

    handle.join().expect("mock server");
    let ExternalUpdateOutcome::PreconditionFailed { current } = outcome else {
        panic!("stale precondition must fail");
    };
    assert_eq!(current.title, "Remote edit");
    assert_eq!(current.body, "Remote body");
    assert_eq!(current.project_id.as_deref(), Some("project-1"));
    assert_eq!(current.updated_at.as_deref(), Some("provider-revision-2"));
    assert_eq!(
        current.reference.url.as_deref(),
        Some("https://app.todoist.com/app/task/remote-1")
    );
    assert_eq!(
        captured.lock().expect("captured request").path,
        "/tasks/remote-1"
    );
}

#[test]
fn todoist_update_classifies_metadata_and_status_changes() {
    let metadata = ExternalTaskUpdate::new(vec![ExternalSyncField::Title]);
    let status = ExternalTaskUpdate::new(vec![ExternalSyncField::Status]);

    assert!(metadata.changes_metadata());
    assert!(!metadata.changes_status());
    assert!(!status.changes_metadata());
    assert!(status.changes_status());
}

#[test]
fn todoist_project_filter_admits_only_matching_project_ids() {
    assert!(todoist_project_matches_filter(
        Some("proj-1"),
        &["proj-1".into()]
    ));
    assert!(!todoist_project_matches_filter(
        Some("proj-2"),
        &["proj-1".into()]
    ));
    assert!(todoist_project_matches_filter(
        Some("proj-1"),
        &[" Proj-1 ".into()]
    ));
    assert!(todoist_project_matches_filter(Some("proj-1"), &[]));
    assert!(!todoist_project_matches_filter(None, &["proj-1".into()]));
    assert!(todoist_project_matches_filter(None, &[]));
}

#[tokio::test]
async fn todoist_pull_drops_tasks_outside_project_filter() {
    let body = r#"{
        "results": [
            {"id":"a","content":"In scope","description":"","project_id":"proj-keep"},
            {"id":"b","content":"Out of scope","description":"","project_id":"proj-skip"},
            {"id":"c","content":"No project","description":""}
        ],
        "next_cursor": null
    }"#;
    let (endpoint, _captured, handle) = spawn_json_mock_response(body);
    let mut config = ExternalSyncConfig::default()
        .with_todoist_token_override(Some("token"))
        .with_todoist_import_project_ids_override(&["proj-keep".into()]);
    config.todoist_token = Some("token".into());
    let mut client = TodoistSyncClient::new_with_api_base("token", endpoint).expect("client");
    client.import_project_ids = config.todoist_import_project_ids().to_vec();

    let tasks = client.pull_tasks().await.expect("pull tasks");

    handle.join().expect("mock server");
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].reference.external_id, "a");
    assert_eq!(tasks[0].status, TaskBoardStatus::Backlog);
    assert_eq!(tasks[0].project_id.as_deref(), Some("proj-keep"));
    assert_eq!(
        tasks[0].reference.url.as_deref(),
        Some("https://app.todoist.com/app/task/a")
    );
}

fn spawn_json_mock_response(
    response_body: &str,
) -> (String, Arc<Mutex<CapturedRequest>>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured = Arc::new(Mutex::new(CapturedRequest::default()));
    let captured_clone = Arc::clone(&captured);
    let body = response_body.to_string();
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let request = read_http_request(&mut stream);
        *captured_clone.lock().expect("captured request") = capture_request(&request);
        write_json_response(&mut stream, &body);
    });
    (endpoint, captured, handle)
}

fn local_item_with_status(status: TaskBoardStatus) -> TaskBoardItem {
    let mut item = local_item("Local task", "", None);
    item.status = status;
    item
}

fn local_item(title: &str, body: &str, project_id: Option<&str>) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        "task-1".to_string(),
        title.to_string(),
        body.to_string(),
        "2026-05-15T00:00:00Z".to_string(),
    );
    item.project_id = project_id.map(ToString::to_string);
    item
}

fn spawn_status_mock() -> (String, Arc<Mutex<CapturedRequest>>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured = Arc::new(Mutex::new(CapturedRequest::default()));
    let captured_clone = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let request = read_http_request(&mut stream);
        *captured_clone.lock().expect("captured request") = capture_request(&request);
        write_json_response(&mut stream, "{}");
    });
    (endpoint, captured, handle)
}

fn spawn_json_mock(
    response_body: &'static str,
) -> (String, Arc<Mutex<CapturedRequest>>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured = Arc::new(Mutex::new(CapturedRequest::default()));
    let captured_clone = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let request = read_http_request(&mut stream);
        *captured_clone.lock().expect("captured request") = capture_request(&request);
        write_json_response(&mut stream, response_body);
    });
    (endpoint, captured, handle)
}

fn spawn_sequence_mock(
    responses: Vec<(&'static str, &'static str)>,
) -> (
    String,
    Arc<Mutex<Vec<CapturedRequest>>>,
    thread::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured = Arc::new(Mutex::new(Vec::new()));
    let captured_clone = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        for (status, body) in responses {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = read_http_request(&mut stream);
            captured_clone
                .lock()
                .expect("captured requests")
                .push(capture_request(&request));
            write_http_response(&mut stream, status, body);
        }
    });
    (endpoint, captured, handle)
}

fn capture_request(request: &str) -> CapturedRequest {
    let request_line = request.lines().next().unwrap_or_default();
    let method = request_line
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_string();
    let path = request_line
        .split_whitespace()
        .nth(1)
        .unwrap_or_default()
        .to_string();
    let authorization = request.lines().find_map(|line| {
        line.split_once(':').and_then(|(name, value)| {
            name.eq_ignore_ascii_case("authorization")
                .then(|| value.trim().to_string())
        })
    });
    let request_id = request.lines().find_map(|line| {
        line.split_once(':').and_then(|(name, value)| {
            name.eq_ignore_ascii_case("x-request-id")
                .then(|| value.trim().to_string())
        })
    });
    let body = request
        .split("\r\n\r\n")
        .nth(1)
        .unwrap_or_default()
        .to_string();
    CapturedRequest {
        method,
        path,
        authorization,
        request_id,
        body,
    }
}

fn read_http_request(stream: &mut TcpStream) -> String {
    stream.set_nonblocking(false).expect("blocking stream");
    stream
        .set_read_timeout(Some(std::time::Duration::from_secs(1)))
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
    read_http_request_body(stream, &mut buffer);
    String::from_utf8(buffer).expect("utf8 request")
}

fn read_http_request_body(stream: &mut TcpStream, buffer: &mut Vec<u8>) {
    let header_end = buffer
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .map(|position| position + 4)
        .unwrap_or(buffer.len());
    let headers = String::from_utf8(buffer[..header_end].to_vec()).expect("utf8 headers");
    let content_length = headers
        .lines()
        .find_map(|line| {
            line.split_once(':').and_then(|(name, value)| {
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            })
        })
        .unwrap_or_default();
    while buffer.len().saturating_sub(header_end) < content_length {
        let mut chunk = [0_u8; 1024];
        let read = stream.read(&mut chunk).expect("read request body");
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
    }
}

fn write_http_response(stream: &mut TcpStream, status: &str, body: &str) {
    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .expect("write response");
    stream.flush().expect("flush response");
}

fn write_json_response(stream: &mut TcpStream, body: &str) {
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .expect("write response");
    stream.flush().expect("flush response");
}

fn body_json(body: &str) -> Value {
    serde_json::from_str(body).expect("request body json")
}
