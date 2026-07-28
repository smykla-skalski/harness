use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::json;

use super::*;
use harness_github_api::acquire_global_budget_test_lock;

#[test]
fn github_inbox_search_queries_use_github_all_state_issue_form() {
    let repository = parse_github_repository("owner/repo").expect("repository");
    let assigned_query = assigned_issue_query(&repository, "octo-user");

    assert_eq!(
        assigned_query,
        "repo:owner/repo is:issue assignee:octo-user state:open state:closed"
    );
    assert_eq!(
        review_request_query(&repository, "octo-user"),
        "repo:owner/repo is:pr review-requested:octo-user state:open"
    );
    assert_eq!(
        dependency_author_query(&repository, "renovate[bot]"),
        "repo:owner/repo is:pr is:open author:renovate[bot]"
    );
    assert_eq!(
        dependency_author_query(&repository, "dependabot[bot]"),
        "repo:owner/repo is:pr is:open author:dependabot[bot]"
    );
    assert_eq!(
        dependency_label_query(&repository),
        "repo:owner/repo is:pr is:open label:dependencies"
    );
}

#[test]
fn search_label_filter_admits_only_matching_labels() {
    assert!(search_label_matches_filter(
        &["bug".into(), "automation".into()],
        &["automation".into()]
    ));
    assert!(!search_label_matches_filter(
        &["docs".into()],
        &["automation".into()]
    ));
    assert!(search_label_matches_filter(
        &["bug".into()],
        &[" Bug ".into()]
    ));
    assert!(search_label_matches_filter(&["bug".into()], &[]));
}

#[tokio::test]
async fn github_inbox_pull_skips_failed_repository_and_keeps_pullable_tasks() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(
            422,
            json!({
                "message": "Validation Failed",
                "errors": [{
                    "message": "The listed users and repositories cannot be searched either \
                        because the resources do not exist or you do not have permission to view \
                        them.",
                    "resource": "Search",
                    "field": "q",
                    "code": "invalid"
                }]
            }),
        ),
        MockResponse::json(
            200,
            search_response_with_issue("https://example.test/good/7"),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["bad/repo", "good/repo"]);

    let tasks = client.pull_tasks().await.expect("partial inbox pull");

    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    // viewer + bad(assigned fails) + good(assigned, review, two dependency-bot
    // searches, dependency-labelled)
    assert_eq!(requests.len(), 7);
    assert!(requests[1].contains("repo:bad/repo"));
    assert!(requests[2].contains("repo:good/repo"));
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].reference.external_id, "good/repo#7");
    assert_eq!(tasks[0].status, TaskBoardStatus::Inbox);
}

#[tokio::test]
async fn github_inbox_pull_imports_review_requests_as_inbox() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(
            200,
            search_response_with_issue("https://example.test/good/pull/7"),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);

    let tasks = client.pull_tasks().await.expect("inbox pull");

    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    // viewer + assigned + review + two dependency-bot searches + dependency label
    assert_eq!(requests.len(), 6);
    assert!(requests[2].contains("review-requested:octo-user"));
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].status, TaskBoardStatus::Inbox);
}

#[tokio::test]
async fn github_inbox_review_request_tasks_parse_the_same_tracking_convention_as_issues() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, _requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(
            200,
            search_response_with_issue_body("https://example.test/good/pull/7", "Part of #5"),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);

    let tasks = client.pull_tasks().await.expect("inbox pull");

    handle.join().expect("mock server");
    assert_eq!(tasks.len(), 1);
    assert_eq!(
        tasks[0]
            .parent_reference
            .as_ref()
            .map(|reference| reference.external_id.as_str()),
        Some("good/repo#5")
    );
}

#[tokio::test]
async fn github_inbox_pull_maps_closed_assigned_issues_to_done() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, _requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(
            200,
            search_response_with_issue_state("https://example.test/good/7", "CLOSED"),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);

    let tasks = client.pull_tasks().await.expect("inbox pull");

    handle.join().expect("mock server");
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].status, TaskBoardStatus::Done);
}

#[tokio::test]
async fn github_inbox_discovers_dependency_update_pull_requests() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(
            200,
            search_response_with_pull_request(
                12,
                "https://example.test/good/pull/12",
                "abc123",
                "renovate[bot]",
            ),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);

    let tasks = client.pull_tasks().await.expect("inbox pull");

    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    assert!(requests[3].contains("author:renovate[bot]"));
    assert!(requests[4].contains("author:dependabot[bot]"));
    assert!(requests[5].contains("label:dependencies"));
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].workflow_kind, TaskBoardWorkflowKind::PrFix);
    assert_eq!(tasks[0].pr_head_revision.as_deref(), Some("abc123"));
    assert_eq!(tasks[0].pr_author.as_deref(), Some("renovate[bot]"));
    assert_eq!(tasks[0].status, TaskBoardStatus::Inbox);
}

#[tokio::test]
async fn github_inbox_folds_a_pull_request_with_both_intents_into_one_ticket() {
    let _guard = acquire_global_budget_test_lock().await;
    // The same pull request #7 is both review-requested and a dependency update,
    // so it must import once carrying both intents rather than twice.
    let (endpoint, _requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(
            200,
            search_response_with_pull_request(
                7,
                "https://example.test/good/pull/7",
                "deadbeef",
                "renovate[bot]",
            ),
        ),
        MockResponse::json(
            200,
            search_response_with_pull_request(
                7,
                "https://example.test/good/pull/7",
                "deadbeef",
                "renovate[bot]",
            ),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);

    let tasks = client.pull_tasks().await.expect("inbox pull");

    handle.join().expect("mock server");
    assert_eq!(tasks.len(), 1, "both intents fold into one ticket");
    assert_eq!(tasks[0].workflow_kind, TaskBoardWorkflowKind::PrFixReview);
    assert_eq!(tasks[0].pr_head_revision.as_deref(), Some("deadbeef"));
}

#[tokio::test]
async fn github_inbox_pull_fails_when_no_repository_can_be_pulled() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, _requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(
            422,
            json!({
                "message": "Validation Failed",
                "errors": [{
                    "message": "The listed users and repositories cannot be searched either \
                        because the resources do not exist or you do not have permission to view \
                        them.",
                    "resource": "Search",
                    "field": "q",
                    "code": "invalid"
                }]
            }),
        ),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["bad/repo"]);

    let error = client
        .pull_tasks()
        .await
        .expect_err("all repositories fail");

    handle.join().expect("mock server");
    assert!(
        error
            .message()
            .contains("failed for all configured repositories")
    );
    assert!(
        error
            .details()
            .expect("details")
            .contains("bad/repo assigned issue search failed")
    );
}

fn inbox_client_with_base_uri(base_uri: &str, repositories: &[&str]) -> GitHubInboxSyncClient {
    let client = harness_github_api::GitHubProtectedClient::with_base_url("token", base_uri)
        .expect("protected client");
    let repositories = repositories
        .iter()
        .map(|repository| parse_github_repository(repository))
        .collect::<Result<Vec<_>, _>>()
        .expect("repositories");
    GitHubInboxSyncClient {
        client,
        repositories,
        import_labels: Vec::new(),
        include_review_requests: true,
    }
}

fn search_response_with_issue(url: &str) -> serde_json::Value {
    search_response_with_issue_state(url, "OPEN")
}

fn search_response_with_issue_state(url: &str, state: &str) -> serde_json::Value {
    json!({
        "data": {
            "search": {
                "pageInfo": {
                    "hasNextPage": false,
                    "endCursor": null
                },
                "nodes": [{
                    "number": 7,
                    "title": "Keep pullable repo",
                    "body": null,
                    "url": url,
                    "state": state,
                    "updatedAt": "2026-05-19T00:00:00Z",
                    "labels": { "nodes": [] }
                }]
            }
        }
    })
}

fn search_response_with_issue_body(url: &str, body: &str) -> serde_json::Value {
    json!({
        "data": {
            "search": {
                "pageInfo": {
                    "hasNextPage": false,
                    "endCursor": null
                },
                "nodes": [{
                    "number": 7,
                    "title": "Keep pullable repo",
                    "body": body,
                    "url": url,
                    "state": "OPEN",
                    "updatedAt": "2026-05-19T00:00:00Z",
                    "labels": { "nodes": [] }
                }]
            }
        }
    })
}

fn search_response_with_pull_request(
    number: u64,
    url: &str,
    head: &str,
    author: &str,
) -> serde_json::Value {
    json!({
        "data": {
            "search": {
                "pageInfo": { "hasNextPage": false, "endCursor": null },
                "nodes": [{
                    "number": number,
                    "title": "Bump serde to 1.0.200",
                    "body": null,
                    "url": url,
                    "state": "OPEN",
                    "updatedAt": "2026-05-19T00:00:00Z",
                    "headRefOid": head,
                    "author": { "login": author },
                    "labels": { "nodes": [{ "name": "dependencies" }] }
                }]
            }
        }
    })
}

fn empty_search_response() -> serde_json::Value {
    json!({
        "data": {
            "search": {
                "pageInfo": {
                    "hasNextPage": false,
                    "endCursor": null
                },
                "nodes": []
            }
        }
    })
}

fn viewer_response(login: &str) -> serde_json::Value {
    json!({
        "data": {
            "viewer": {
                "login": login
            }
        }
    })
}

struct MockResponse {
    status: u16,
    body: serde_json::Value,
}

impl MockResponse {
    fn json(status: u16, body: serde_json::Value) -> Self {
        Self { status, body }
    }
}

fn spawn_sequence_mock(
    responses: Vec<MockResponse>,
) -> (String, Arc<Mutex<Vec<String>>>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let captured = Arc::clone(&requests);
    let handle = thread::spawn(move || {
        for response in responses {
            let (mut stream, _) = listener.accept().expect("accept");
            let request = read_http_request(&mut stream);
            captured.lock().expect("captured requests").push(request);
            write_http_response(&mut stream, &response);
        }
    });
    (endpoint, requests, handle)
}

fn read_http_request(stream: &mut TcpStream) -> String {
    let mut buffer = [0_u8; 4096];
    let mut request = Vec::new();
    loop {
        let count = stream.read(&mut buffer).expect("read");
        if count == 0 {
            break;
        }
        request.extend_from_slice(&buffer[..count]);
        if headers_and_body_complete(&request) {
            break;
        }
    }
    String::from_utf8(request).expect("utf8 request")
}

fn headers_and_body_complete(request: &[u8]) -> bool {
    let request = String::from_utf8_lossy(request);
    let Some((headers, body)) = request.split_once("\r\n\r\n") else {
        return false;
    };
    let content_length = headers
        .lines()
        .find_map(|line| {
            line.split_once(':').and_then(|(name, value)| {
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            })
        })
        .unwrap_or(0);
    body.len() >= content_length
}

fn write_http_response(stream: &mut TcpStream, response: &MockResponse) {
    let reason = if response.status == 200 {
        "OK"
    } else {
        "Unprocessable Entity"
    };
    let body = response.body.to_string();
    write!(
        stream,
        "HTTP/1.1 {} {}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
        response.status,
        reason,
        body.len(),
        body
    )
    .expect("write response");
}
