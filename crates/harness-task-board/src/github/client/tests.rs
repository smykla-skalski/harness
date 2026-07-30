use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use serde_json::json;

use super::*;

#[derive(Debug, Default)]
struct CapturedRequest {
    path: String,
    body: String,
}

#[tokio::test]
async fn request_pull_request_reviewers_posts_expected_payload() {
    let _budget_guard = harness_github_api::acquire_global_budget_test_lock().await;
    let (endpoint, captured, handle) = spawn_json_mock(json!({
        "id": 1,
        "node_id": "PRR_1",
        "html_url": "https://github.invalid/owner/repo/pull/42#pullrequestreview-1",
        "user": null
    }));
    let client = automation_client_with_base_uri(&endpoint);
    let config = GitHubProjectConfig::new("owner", "repo");

    client
        .request_pull_request_reviewers(
            &config,
            42,
            &["alice".to_string(), "bob".to_string()],
            &["core".to_string()],
        )
        .await
        .expect("request reviewers");

    handle.join().expect("mock server");
    let captured = captured.lock().expect("captured request");
    assert_eq!(
        captured.path,
        "/repos/owner/repo/pulls/42/requested_reviewers"
    );
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&captured.body).expect("json body"),
        json!({
            "reviewers": ["alice", "bob"],
            "team_reviewers": ["core"]
        })
    );
}

#[tokio::test]
async fn approve_pull_request_posts_expected_payload() {
    let _budget_guard = harness_github_api::acquire_global_budget_test_lock().await;
    let (endpoint, captured, handle) = spawn_json_mock(json!({
        "id": 1,
        "node_id": "PRR_1",
        "html_url": "https://github.invalid/owner/repo/pull/42#pullrequestreview-1",
        "state": "APPROVED",
        "user": null
    }));
    let client = automation_client_with_base_uri(&endpoint);
    let config = GitHubProjectConfig::new("owner", "repo");

    client
        .approve_pull_request(&config, 42, "verified-head")
        .await
        .expect("approve pull request");

    handle.join().expect("mock server");
    let captured = captured.lock().expect("captured request");
    assert_eq!(captured.path, "/repos/owner/repo/pulls/42/reviews");
    assert_eq!(
        serde_json::from_str::<serde_json::Value>(&captured.body).expect("json body"),
        json!({
            "commit_id": "verified-head",
            "event": "APPROVE"
        })
    );
}

#[test]
fn rest_pull_request_handle_maps_response_entries() {
    let pull_request: RestPullRequestResponse = serde_json::from_value(json!({
        "number": 42,
        "html_url": "https://github.invalid/owner/repo/pull/42",
        "draft": true,
        "state": "open",
        "merged": false,
        "head": {
            "sha": "deadbeef",
            "ref": "feature/fix",
            "repo": { "full_name": "contributor/fork" }
        },
        "requested_reviewers": [
            { "login": "reviewer" }
        ],
        "requested_teams": [
            { "slug": "core" }
        ]
    }))
    .expect("rest pull request");

    let handle = rest_pull_request_handle(pull_request);

    assert_eq!(
        handle,
        GitHubPullRequestHandle {
            number: 42,
            html_url: Some("https://github.invalid/owner/repo/pull/42".into()),
            draft: true,
            open: true,
            merged: false,
            head_sha: "deadbeef".into(),
            head_repository: Some("contributor/fork".into()),
            head_branch: Some("feature/fix".into()),
            requested_reviewers: vec!["reviewer".into()],
            requested_team_reviewers: vec!["core".into()],
        }
    );
}

#[test]
fn rest_pull_request_handle_fails_closed_without_open_state() {
    let pull_request: RestPullRequestResponse = serde_json::from_value(json!({
        "number": 42,
        "html_url": "https://github.invalid/owner/repo/pull/42",
        "draft": false,
        "merged": false,
        "head": {
            "sha": "deadbeef",
            "ref": "feature/fix",
            "repo": { "full_name": "contributor/fork" }
        }
    }))
    .expect("rest pull request");

    assert!(!rest_pull_request_handle(pull_request).open);
}

#[test]
fn graphql_pull_request_handles_request_open_state() {
    for query in [
        super::super::client_graphql::PULL_REQUEST_HANDLE_QUERY,
        super::super::client_graphql::OPEN_PULL_REQUEST_FOR_BRANCH_QUERY,
    ] {
        assert!(query.lines().any(|line| line.trim() == "state"));
    }
}

fn automation_client_with_base_uri(base_uri: &str) -> GitHubApiAutomationClient {
    let client = harness_github_api::GitHubProtectedClient::with_base_url("token", base_uri)
        .expect("protected client");
    GitHubApiAutomationClient {
        client,
        token: "token".to_string(),
        runtime_config: TaskBoardGitRuntimeConfig::default(),
    }
}

#[test]
fn automation_client_keeps_database_runtime_profile() {
    let runtime_config = TaskBoardGitRuntimeConfig {
        global: crate::TaskBoardGitRuntimeProfile {
            author_name: Some("Database Author".to_string()),
            ..Default::default()
        },
        repository_overrides: Vec::new(),
    };
    let client = GitHubApiAutomationClient::new_with_runtime_config("token", runtime_config)
        .expect("automation client");
    assert_eq!(
        client.runtime_config.global.author_name.as_deref(),
        Some("Database Author")
    );
}

fn spawn_json_mock(
    response_body: serde_json::Value,
) -> (String, Arc<Mutex<CapturedRequest>>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let endpoint = format!("http://{}", listener.local_addr().expect("addr"));
    let captured = Arc::new(Mutex::new(CapturedRequest::default()));
    let captured_clone = Arc::clone(&captured);
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept");
        let request = read_http_request(&mut stream);
        *captured_clone.lock().expect("captured request") = capture_request(&request);
        write_http_response(&mut stream, response_body.to_string().as_str());
    });
    (endpoint, captured, handle)
}

fn capture_request(request: &str) -> CapturedRequest {
    let path = request
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .unwrap_or_default()
        .to_string();
    let body = request
        .split("\r\n\r\n")
        .nth(1)
        .unwrap_or_default()
        .to_string();
    CapturedRequest { path, body }
}

fn read_http_request(stream: &mut TcpStream) -> String {
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .expect("read timeout");
    let mut buffer = Vec::new();
    loop {
        let mut chunk = [0_u8; 1024];
        let read = stream.read(&mut chunk).expect("read request");
        if read == 0 {
            break;
        }
        buffer.extend_from_slice(&chunk[..read]);
        let request = String::from_utf8_lossy(&buffer);
        if headers_and_body_complete(request.as_ref()) {
            break;
        }
    }
    String::from_utf8(buffer).expect("utf8 request")
}

fn headers_and_body_complete(request: &str) -> bool {
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

fn write_http_response(stream: &mut TcpStream, body: &str) {
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream
        .write_all(response.as_bytes())
        .expect("write response");
    stream.flush().expect("flush response");
}
