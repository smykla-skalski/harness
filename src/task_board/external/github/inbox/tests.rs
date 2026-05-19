use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::json;

use super::*;

#[test]
fn github_inbox_search_queries_scope_assigned_issues_and_review_requests() {
    let repository = parse_github_repository("owner/repo").expect("repository");

    assert_eq!(
        assigned_issue_query(&repository, "octo-user"),
        "repo:owner/repo is:issue assignee:octo-user state:all"
    );
    assert_eq!(
        review_request_query(&repository, "octo-user"),
        "repo:owner/repo is:pr review-requested:octo-user state:open"
    );
}

#[test]
fn github_inbox_search_payload_serializes_query_page_and_page_size() {
    let payload = GitHubSearchIssuePullRequestQuery {
        q: "repo:owner/repo is:pr review-requested:octo-user state:open".into(),
        per_page: 100,
        page: 2,
    };

    assert_eq!(
        serde_json::to_value(payload).expect("serialize payload"),
        json!({
            "q": "repo:owner/repo is:pr review-requested:octo-user state:open",
            "per_page": 100,
            "page": 2
        })
    );
}

#[test]
fn github_inbox_search_item_deserializes_label_names() {
    let payload = json!({
        "number": 42,
        "title": "Fix bug",
        "body": null,
        "html_url": "https://example.com/i/42",
        "state": "open",
        "updated_at": "2026-05-15T00:00:00Z",
        "labels": [{ "name": "needs-fix" }, { "name": "automation" }]
    });

    let item: GitHubSearchIssuePullRequestItem =
        serde_json::from_value(payload).expect("deserialize search item");

    assert_eq!(
        item.label_names(),
        vec!["needs-fix".to_string(), "automation".to_string()]
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

#[test]
fn github_search_page_cap_keeps_total_hits_under_one_thousand() {
    assert_eq!(GITHUB_SEARCH_PAGE_CAP, 10);
}

#[tokio::test]
async fn github_inbox_pull_skips_failed_repository_and_keeps_pullable_tasks() {
    let (endpoint, requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, json!({ "login": "octo-user" })),
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
        MockResponse::json(200, json!({ "items": [] })),
    ]);
    let client = inbox_client_with_base_uri(endpoint, &["bad/repo", "good/repo"]);

    let tasks = client.pull_tasks().await.expect("partial inbox pull");

    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    assert_eq!(requests.len(), 4);
    assert!(requests[1].contains("repo%3Abad%2Frepo"));
    assert!(requests[2].contains("repo%3Agood%2Frepo"));
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].reference.external_id, "good/repo#7");
}

#[tokio::test]
async fn github_inbox_pull_fails_when_no_repository_can_be_pulled() {
    let (endpoint, _requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, json!({ "login": "octo-user" })),
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
    let client = inbox_client_with_base_uri(endpoint, &["bad/repo"]);

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

fn inbox_client_with_base_uri(base_uri: String, repositories: &[&str]) -> GitHubInboxSyncClient {
    ensure_rustls_provider();
    let client = octocrab::Octocrab::builder()
        .personal_token("token".to_string())
        .base_uri(base_uri)
        .expect("base uri")
        .build()
        .expect("octocrab client");
    let repositories = repositories
        .iter()
        .map(|repository| parse_github_repository(repository))
        .collect::<Result<Vec<_>, _>>()
        .expect("repositories");
    GitHubInboxSyncClient {
        client,
        repositories,
        import_labels: Vec::new(),
    }
}

fn search_response_with_issue(url: &str) -> serde_json::Value {
    json!({
        "items": [{
            "number": 7,
            "title": "Keep pullable repo",
            "body": null,
            "html_url": url,
            "state": "open",
            "updated_at": "2026-05-19T00:00:00Z",
            "labels": []
        }]
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
            captured
                .lock()
                .expect("captured requests")
                .push(request_target(&request));
            write_http_response(&mut stream, response);
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
        if request.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
    }
    String::from_utf8(request).expect("utf8 request")
}

fn request_target(request: &str) -> String {
    request
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .expect("request target")
        .to_string()
}

fn write_http_response(stream: &mut TcpStream, response: MockResponse) {
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
