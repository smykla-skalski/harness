use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use super::super::*;
use crate::github_api::GitHubProtectedClient;

#[derive(Debug, Default)]
struct CapturedRequest {
    method: String,
    path: String,
    body: String,
}

#[tokio::test]
async fn stale_github_precondition_returns_fresh_remote_snapshot_without_patch() {
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![
        issue_revision_response("provider-revision-2"),
        issue_response(
            "Remote edit",
            "Remote body",
            "closed",
            "provider-revision-2",
        ),
    ]);
    let client = sync_client(&endpoint);
    let item = local_item();
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "acme/widgets#17");

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
    assert_eq!(current.status, TaskBoardStatus::Done);
    assert_eq!(current.project_id.as_deref(), Some("acme/widgets"));
    assert_eq!(current.updated_at.as_deref(), Some("provider-revision-2"));
    let captured = captured.lock().expect("captured requests");
    assert_eq!(captured.len(), 2);
    assert_eq!(captured[0].method, "POST");
    assert_eq!(captured[0].path, "/graphql");
    assert_eq!(captured[1].method, "GET");
    assert_eq!(captured[1].path, "/repos/acme/widgets/issues/17");
}

#[tokio::test]
async fn matching_github_precondition_reads_fresh_then_patches() {
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![
        issue_revision_response("provider-revision-1"),
        issue_response("Base title", "Remote body", "open", "provider-revision-1"),
        issue_response("Local edit", "Remote body", "open", "provider-revision-2"),
    ]);
    let client = sync_client(&endpoint);
    let item = local_item();
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "acme/widgets#17");

    let outcome = client
        .update_task(
            &item,
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Title])
                .with_precondition_updated_at(Some("provider-revision-1".into())),
        )
        .await
        .expect("update issue");

    handle.join().expect("mock server");
    let ExternalUpdateOutcome::Applied {
        provider_revision, ..
    } = outcome
    else {
        panic!("matching precondition must apply");
    };
    assert_eq!(provider_revision.as_deref(), Some("provider-revision-2"));
    let captured = captured.lock().expect("captured requests");
    assert_eq!(captured.len(), 3);
    assert_eq!(captured[0].method, "POST");
    assert_eq!(captured[1].method, "GET");
    assert_eq!(captured[2].method, "PATCH");
    assert_eq!(captured[2].path, "/repos/acme/widgets/issues/17");
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&captured[2].body).expect("request body")["title"],
        "Local edit"
    );
}

fn sync_client(endpoint: &str) -> GitHubSyncClient {
    GitHubSyncClient {
        client: GitHubProtectedClient::with_base_url("token", endpoint).expect("client"),
        repository: Some(GitHubRepository {
            owner: "acme".into(),
            repo: "widgets".into(),
        }),
        pull_enabled: false,
        import_labels: Vec::new(),
    }
}

fn local_item() -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        "task-1".into(),
        "Local edit".into(),
        "Local body".into(),
        "2026-07-16T10:00:00Z".into(),
    );
    item.project_id = Some("acme/widgets".into());
    item
}

fn issue_response(title: &str, body: &str, state: &str, updated_at: &str) -> String {
    serde_json::json!({
        "number": 17,
        "html_url": "https://github.test/acme/widgets/issues/17",
        "title": title,
        "body": body,
        "state": state,
        "updated_at": updated_at,
    })
    .to_string()
}

fn issue_revision_response(updated_at: &str) -> String {
    serde_json::json!({
        "data": {
            "repository": {
                "issue": {
                    "updatedAt": updated_at,
                }
            }
        }
    })
    .to_string()
}

fn spawn_sequence_mock(
    responses: Vec<String>,
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
        for body in responses {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = read_http_request(&mut stream);
            captured_clone
                .lock()
                .expect("captured requests")
                .push(capture_request(&request));
            write_json_response(&mut stream, &body);
        }
    });
    (endpoint, captured, handle)
}

fn capture_request(request: &str) -> CapturedRequest {
    let mut request_line = request
        .lines()
        .next()
        .unwrap_or_default()
        .split_whitespace();
    CapturedRequest {
        method: request_line.next().unwrap_or_default().into(),
        path: request_line.next().unwrap_or_default().into(),
        body: request.split("\r\n\r\n").nth(1).unwrap_or_default().into(),
    }
}

fn read_http_request(stream: &mut TcpStream) -> String {
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
