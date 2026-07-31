use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::json;

use super::super::*;

pub(super) fn inbox_client_with_base_uri(
    base_uri: &str,
    repositories: &[&str],
) -> GitHubInboxSyncClient {
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
        last_pull_complete: Arc::new(AtomicBool::new(true)),
        batch: None,
    }
}

pub(super) fn assigned_only_inbox_client(
    base_uri: &str,
    repositories: &[&str],
) -> GitHubInboxSyncClient {
    let mut client = inbox_client_with_base_uri(base_uri, repositories);
    client.include_review_requests = false;
    client
}

pub(super) fn assigned_only_batched_clients(
    base_uri: &str,
    repositories: &[&str],
) -> Vec<GitHubInboxSyncClient> {
    assigned_only_batched_clients_with_fresh(base_uri, repositories, true)
}

pub(super) fn assigned_only_background_batched_clients(
    base_uri: &str,
    repositories: &[&str],
) -> Vec<GitHubInboxSyncClient> {
    assigned_only_batched_clients_with_fresh(base_uri, repositories, false)
}

fn assigned_only_batched_clients_with_fresh(
    base_uri: &str,
    repositories: &[&str],
    fresh: bool,
) -> Vec<GitHubInboxSyncClient> {
    let client = harness_github_api::GitHubProtectedClient::with_base_url("token", base_uri)
        .expect("protected client");
    let repositories = repositories
        .iter()
        .map(|repository| parse_github_repository(repository))
        .collect::<Result<Vec<_>, _>>()
        .expect("repositories");
    let batch = Arc::new(batch::InboxBatch::new(
        client.clone(),
        repositories.clone(),
        Vec::new(),
        fresh,
        false,
    ));
    repositories
        .into_iter()
        .map(|repository| GitHubInboxSyncClient {
            client: client.clone(),
            repositories: vec![repository],
            import_labels: Vec::new(),
            include_review_requests: false,
            last_pull_complete: Arc::new(AtomicBool::new(true)),
            batch: Some(Arc::clone(&batch)),
        })
        .collect()
}

pub(super) fn batched_clients_with_reviews(
    base_uri: &str,
    repositories: &[&str],
) -> Vec<GitHubInboxSyncClient> {
    let client = harness_github_api::GitHubProtectedClient::with_base_url("token", base_uri)
        .expect("protected client");
    let repositories = repositories
        .iter()
        .map(|repository| parse_github_repository(repository))
        .collect::<Result<Vec<_>, _>>()
        .expect("repositories");
    let batch = Arc::new(batch::InboxBatch::new(
        client.clone(),
        repositories.clone(),
        Vec::new(),
        true,
        true,
    ));
    repositories
        .into_iter()
        .map(|repository| GitHubInboxSyncClient {
            client: client.clone(),
            repositories: vec![repository],
            import_labels: Vec::new(),
            include_review_requests: true,
            last_pull_complete: Arc::new(AtomicBool::new(true)),
            batch: Some(Arc::clone(&batch)),
        })
        .collect()
}

pub(super) fn empty_batch_search_response(query_count: usize) -> serde_json::Value {
    let data = (0..query_count)
        .map(|index| {
            (
                format!("q{index}"),
                json!({
                    "pageInfo": { "hasNextPage": false, "endCursor": null },
                    "nodes": []
                }),
            )
        })
        .collect::<serde_json::Map<_, _>>();
    json!({ "data": data })
}

pub(super) fn search_response_with_issue(url: &str) -> serde_json::Value {
    search_response_with_issue_state(url, "OPEN")
}

pub(super) fn search_response_with_issue_state(url: &str, state: &str) -> serde_json::Value {
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

pub(super) fn search_response_with_issue_body(url: &str, body: &str) -> serde_json::Value {
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

pub(super) fn search_response_with_pull_request(
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

pub(super) fn empty_search_response() -> serde_json::Value {
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

pub(super) fn viewer_response(login: &str) -> serde_json::Value {
    json!({
        "data": {
            "viewer": {
                "login": login
            }
        }
    })
}

pub(super) struct MockResponse {
    status: u16,
    body: serde_json::Value,
}

impl MockResponse {
    pub(super) fn json(status: u16, body: serde_json::Value) -> Self {
        Self { status, body }
    }
}

pub(super) fn spawn_sequence_mock(
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
