use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::json;

use super::*;

#[derive(Debug, Default)]
struct CapturedRequest {
    path: String,
    body: String,
}

#[tokio::test]
async fn request_pull_request_reviewers_posts_expected_payload() {
    let (endpoint, captured, handle) = spawn_json_mock(json!({
        "id": 1,
        "node_id": "PRR_1",
        "html_url": "https://github.invalid/owner/repo/pull/42#pullrequestreview-1",
        "user": null
    }));
    let client = automation_client_with_base_uri(endpoint);
    let config = GitHubProjectConfig::new("owner", "repo", PathBuf::from("."));

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

#[test]
fn handle_from_simple_pull_request_maps_listing_entries() {
    let pull_request: models::pulls::SimplePullRequest =
        serde_json::from_value(json!({
            "url": "https://api.github.invalid/repos/owner/repo/pulls/42",
            "id": 42,
            "node_id": "PR_kwDOExample",
            "html_url": "https://github.invalid/owner/repo/pull/42",
            "diff_url": "https://github.invalid/owner/repo/pull/42.diff",
            "patch_url": "https://github.invalid/owner/repo/pull/42.patch",
            "issue_url": "https://api.github.invalid/repos/owner/repo/issues/42",
            "commits_url": "https://api.github.invalid/repos/owner/repo/pulls/42/commits",
            "review_comments_url": "https://api.github.invalid/repos/owner/repo/pulls/comments{/number}",
            "review_comment_url": "https://api.github.invalid/repos/owner/repo/pulls/comments{/number}",
            "comments_url": "https://api.github.invalid/repos/owner/repo/issues/42/comments",
            "statuses_url": "https://api.github.invalid/repos/owner/repo/statuses/deadbeef",
            "number": 42,
            "state": "open",
            "locked": false,
            "title": "Keep existing pull request",
            "user": simple_user_json("author", 1),
            "body": null,
            "labels": [],
            "milestone": null,
            "active_lock_reason": null,
            "created_at": "2026-05-18T00:00:00Z",
            "updated_at": "2026-05-18T00:00:00Z",
            "closed_at": null,
            "merged_at": null,
            "merge_commit_sha": null,
            "assignee": null,
            "assignees": null,
            "requested_reviewers": [simple_user_json("reviewer", 2)],
            "requested_teams": [],
            "head": {
                "label": null,
                "ref": "feature-branch",
                "sha": "deadbeef",
                "user": null,
                "repo": null
            },
            "base": {
                "label": null,
                "ref": "main",
                "sha": "cafebabe",
                "user": null,
                "repo": null
            },
            "_links": {},
            "author_association": "MEMBER",
            "auto_merge": null,
            "draft": true
        }))
        .expect("simple pull request");

    let handle = handle_from_simple_pull_request(&pull_request);

    assert_eq!(
        handle,
        GitHubPullRequestHandle {
            number: 42,
            html_url: Some("https://github.invalid/owner/repo/pull/42".into()),
            draft: true,
            merged: false,
            head_sha: "deadbeef".into(),
            requested_reviewers: vec!["reviewer".into()],
            requested_team_reviewers: vec![],
        }
    );
}

fn automation_client_with_base_uri(base_uri: String) -> GitHubApiAutomationClient {
    ensure_rustls_provider();
    let client = octocrab::Octocrab::builder()
        .personal_token("token".to_string())
        .base_uri(base_uri)
        .expect("base uri")
        .build()
        .expect("octocrab client");
    GitHubApiAutomationClient {
        client,
        token: "token".to_string(),
    }
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

fn simple_user_json(login: &str, id: u64) -> serde_json::Value {
    let base = format!("https://api.github.invalid/users/{login}");
    json!({
        "name": null,
        "email": null,
        "login": login,
        "id": id,
        "node_id": format!("MDQ6VXNlcj{id}"),
        "avatar_url": format!("{base}/avatar"),
        "gravatar_id": "",
        "url": base,
        "html_url": format!("https://github.invalid/{login}"),
        "followers_url": format!("{base}/followers"),
        "following_url": format!("{base}/following{{/other_user}}"),
        "gists_url": format!("{base}/gists{{/gist_id}}"),
        "starred_url": format!("{base}/starred{{/owner}}{{/repo}}"),
        "subscriptions_url": format!("{base}/subscriptions"),
        "organizations_url": format!("{base}/orgs"),
        "repos_url": format!("{base}/repos"),
        "events_url": format!("{base}/events{{/privacy}}"),
        "received_events_url": format!("{base}/received_events"),
        "type": "User",
        "site_admin": false,
        "starred_at": null,
        "user_view_type": null
    })
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
