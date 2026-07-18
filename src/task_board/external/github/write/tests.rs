use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use super::super::*;
use super::GitHubIssueResponse;
use crate::github_api::{GitHubProtectedClient, acquire_global_budget_test_lock};

#[derive(Debug, Default)]
struct CapturedRequest {
    method: String,
    path: String,
    body: String,
}

#[test]
fn github_create_uses_configured_repository_and_returns_provider_revision() {
    let client = sync_client("http://127.0.0.1:1");
    let item = local_item();
    let repository = client
        .repository_for(Some(&item))
        .expect("configured repository");
    let issue = GitHubIssueResponse {
        number: 17,
        html_url: "https://github.test/acme/widgets/issues/17".to_owned(),
        title: "Local edit".to_owned(),
        body: Some("Local body".to_owned()),
        state: "open".to_owned(),
        updated_at: Some("provider-revision-1".to_owned()),
    };

    let outcome = created_issue_outcome(&repository, issue);

    assert_eq!(
        outcome.reference.external_id, "acme/widgets#17",
        "provider reference must identify the configured repository"
    );
    assert_eq!(
        outcome.provider_revision.as_deref(),
        Some("provider-revision-1")
    );
    assert_eq!(outcome.provider_project_id.as_deref(), Some("acme/widgets"));
}

#[tokio::test]
async fn stale_github_precondition_returns_fresh_remote_snapshot_without_patch() {
    let _guard = acquire_global_budget_test_lock().await;
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
    let _guard = acquire_global_budget_test_lock().await;
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
    assert_eq!(
        provider_revision,
        ExternalRevisionUpdate::Set("provider-revision-2".into())
    );
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

#[tokio::test]
async fn canonical_repository_mismatch_rejects_update_before_remote_mutation() {
    let client = sync_client("http://127.0.0.1:0");
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "other/widgets#17");

    let error = client
        .update_task(
            &local_item(),
            &reference,
            ExternalTaskUpdate::new(vec![ExternalSyncField::Title]),
        )
        .await
        .expect_err("repository mismatch must fail closed");

    assert_repository_mismatch(&error);
}

#[tokio::test]
async fn canonical_repository_mismatch_rejects_delete_before_remote_mutation() {
    let client = sync_client("http://127.0.0.1:0");
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "other/widgets#17");

    let error = client
        .delete_task(&local_item(), &reference)
        .await
        .expect_err("repository mismatch must fail closed");

    assert_repository_mismatch(&error);
}

#[tokio::test]
async fn matching_canonical_and_legacy_issue_references_remain_compatible() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![
        issue_response("Local edit", "Remote body", "open", "revision-2"),
        issue_response("Local edit", "Remote body", "open", "revision-3"),
        issue_response("Local edit", "Remote body", "closed", "revision-4"),
    ]);
    let client = sync_client(&endpoint);
    let item = local_item();

    for external_id in ["AcMe/WIDGETS#17", "#17"] {
        client
            .update_task(
                &item,
                &ExternalTaskRef::new(ExternalProvider::GitHub, external_id),
                ExternalTaskUpdate::new(vec![ExternalSyncField::Title]),
            )
            .await
            .expect("compatible issue reference");
    }
    client
        .delete_task(&item, &ExternalTaskRef::new(ExternalProvider::GitHub, "17"))
        .await
        .expect("legacy bare issue reference");

    handle.join().expect("mock server");
    let captured = captured.lock().expect("captured requests");
    assert_eq!(captured.len(), 3);
    assert!(captured.iter().all(|request| {
        request.method == "PATCH" && request.path == "/repos/acme/widgets/issues/17"
    }));
}

fn assert_repository_mismatch(error: &CliError) {
    assert_eq!(error.code(), "WORKFLOW_PARSE");
    let message = error.to_string();
    assert!(message.contains("other/widgets"), "{message}");
    assert!(message.contains("acme/widgets"), "{message}");
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
    item.project_id = Some("portfolio-a".into());
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
