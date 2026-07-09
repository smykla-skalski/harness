//! Tests for the REST patch fetcher and its pure helpers. The tests are
//! collected here (rather than split per submodule) because the integration
//! cases need both the helpers and the fetcher visible at once.

use super::fetcher::{
    ConditionalFetchOutcome, RestFetchError, any_patch_matches, fetch_patches,
    fetch_patches_conditional,
};
use super::parsing::{
    RestPullFile, detect_drift, is_truncated_patch, parse_next_link, parse_rest_status,
    rest_file_to_patch, select_patches_by_path, split_repo_full_name,
};
use crate::github_api::GitHubProtectedClient;
use crate::reviews::files::{ReviewFileChangeType, ReviewFileServedBy};

#[test]
fn parse_rest_status_known_values() {
    assert_eq!(parse_rest_status("added"), ReviewFileChangeType::Added);
    assert_eq!(parse_rest_status("removed"), ReviewFileChangeType::Deleted);
    assert_eq!(
        parse_rest_status("modified"),
        ReviewFileChangeType::Modified
    );
    assert_eq!(parse_rest_status("renamed"), ReviewFileChangeType::Renamed);
    assert_eq!(parse_rest_status("copied"), ReviewFileChangeType::Copied);
    assert_eq!(parse_rest_status("changed"), ReviewFileChangeType::Changed);
}

#[test]
fn parse_rest_status_unknown_falls_back_to_other() {
    assert_eq!(parse_rest_status("unchanged"), ReviewFileChangeType::Other);
    assert_eq!(parse_rest_status(""), ReviewFileChangeType::Other);
}

#[test]
fn rest_file_to_patch_propagates_fields() {
    let file = RestPullFile {
        sha: Some("abc".into()),
        filename: "src/lib.rs".into(),
        status: "modified".into(),
        additions: 7,
        deletions: 2,
        changes: 9,
        blob_url: None,
        raw_url: None,
        contents_url: None,
        patch: Some("@@ -1 +1 @@\n-old\n+new".into()),
        previous_filename: None,
    };
    let patch = rest_file_to_patch(&file);
    assert_eq!(patch.path, "src/lib.rs");
    assert_eq!(patch.status, ReviewFileChangeType::Modified);
    assert_eq!(patch.additions, 7);
    assert_eq!(patch.deletions, 2);
    assert!(patch.patch.contains("+new"));
    assert!(!patch.truncated);
    assert_eq!(patch.served_by, ReviewFileServedBy::GithubRest);
    assert!(patch.fetched_at.is_empty());
    assert!(patch.head_ref_oid.is_empty());
}

#[test]
fn rest_file_to_patch_handles_missing_patch() {
    let file = RestPullFile {
        sha: None,
        filename: "image.png".into(),
        status: "modified".into(),
        additions: 0,
        deletions: 0,
        changes: 0,
        blob_url: None,
        raw_url: None,
        contents_url: None,
        patch: None,
        previous_filename: None,
    };
    let patch = rest_file_to_patch(&file);
    assert!(patch.patch.is_empty());
    assert!(!patch.truncated);
}

#[test]
fn truncation_detection_recognises_large_patches() {
    let mut huge = String::new();
    for i in 0..3_000 {
        huge.push_str(&format!("+line{i}\n"));
    }
    assert!(is_truncated_patch(&huge));
}

#[test]
fn truncation_detection_ignores_small_patches() {
    assert!(!is_truncated_patch(""));
    assert!(!is_truncated_patch("@@ -1 +1 @@\n-a\n+b"));
}

#[test]
fn parse_next_link_extracts_url() {
    let header = r#"<https://api.github.com/repos/a/b/pulls/1/files?page=2>; rel="next", <https://api.github.com/repos/a/b/pulls/1/files?page=4>; rel="last""#;
    let next = parse_next_link(header).expect("next link");
    assert_eq!(
        next,
        "https://api.github.com/repos/a/b/pulls/1/files?page=2"
    );
}

#[test]
fn parse_next_link_returns_none_for_terminal_pages() {
    let header = r#"<https://api.github.com/repos/a/b/pulls/1/files?page=1>; rel="prev""#;
    assert!(parse_next_link(header).is_none());
}

#[test]
fn parse_next_link_returns_none_for_empty() {
    assert!(parse_next_link("").is_none());
}

#[test]
fn select_patches_by_path_filters() {
    let files = vec![
        RestPullFile {
            sha: None,
            filename: "src/a.rs".into(),
            status: "modified".into(),
            additions: 1,
            deletions: 0,
            changes: 1,
            blob_url: None,
            raw_url: None,
            contents_url: None,
            patch: Some("+ a".into()),
            previous_filename: None,
        },
        RestPullFile {
            sha: None,
            filename: "src/b.rs".into(),
            status: "modified".into(),
            additions: 2,
            deletions: 0,
            changes: 2,
            blob_url: None,
            raw_url: None,
            contents_url: None,
            patch: Some("+ b".into()),
            previous_filename: None,
        },
    ];
    let requested = vec!["src/b.rs".to_string()];
    let selected = select_patches_by_path(&files, &requested);
    assert_eq!(selected.len(), 1);
    assert_eq!(selected[0].path, "src/b.rs");
}

#[test]
fn select_patches_by_path_empty_request_returns_all() {
    let files = vec![RestPullFile {
        sha: None,
        filename: "src/a.rs".into(),
        status: "modified".into(),
        additions: 1,
        deletions: 0,
        changes: 1,
        blob_url: None,
        raw_url: None,
        contents_url: None,
        patch: Some("+ a".into()),
        previous_filename: None,
    }];
    let selected = select_patches_by_path(&files, &[]);
    assert_eq!(selected.len(), 1);
}

#[test]
fn detect_drift_matches_case_insensitively() {
    assert!(!detect_drift("ABC123", "abc123"));
    assert!(!detect_drift("abc123", "abc123"));
}

#[test]
fn detect_drift_flags_mismatched_oids() {
    assert!(detect_drift("abc123", "def456"));
}

#[test]
fn detect_drift_ignores_empty_inputs() {
    assert!(!detect_drift("", "abc123"));
    assert!(!detect_drift("abc123", ""));
}

/// Spawn a tiny axum mock that serves `payload` for every
/// `GET /repos/{o}/{r}/pulls/{n}/files`. Returns the bound port + the
/// JoinHandle so the test can shut it down.
async fn spawn_mock_pulls_files(payload: serde_json::Value) -> (u16, tokio::task::JoinHandle<()>) {
    use axum::Router;
    use axum::routing::get;
    use tokio::net::TcpListener;

    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let app = Router::new().route(
        "/repos/{owner}/{repo}/pulls/{number}/files",
        get(move || {
            let payload = payload.clone();
            async move { axum::Json(payload) }
        }),
    );
    let server = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    (port, server)
}

fn protected_client_at(port: u16) -> GitHubProtectedClient {
    GitHubProtectedClient::with_base_url("test-token", &format!("http://127.0.0.1:{port}"))
        .expect("protected client")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fetch_patches_returns_all_files_against_mock_server() {
    let _budget_guard = crate::github_api::acquire_global_budget_test_lock().await;
    use serde_json::json;
    let body = json!([
        {
            "sha": "a11", "filename": "src/a.rs", "status": "modified",
            "additions": 1, "deletions": 1, "changes": 2,
            "blob_url": "https://example.com/a", "raw_url": "https://example.com/a",
            "contents_url": "https://example.com/a",
            "patch": "@@ -1 +1 @@\n-a\n+A\n"
        },
        {
            "sha": "b22", "filename": "src/b.rs", "status": "added",
            "additions": 2, "deletions": 0, "changes": 2,
            "blob_url": "https://example.com/b", "raw_url": "https://example.com/b",
            "contents_url": "https://example.com/b",
            "patch": "@@ -0,0 +1,2 @@\n+b1\n+b2\n"
        }
    ]);
    let (port, server) = spawn_mock_pulls_files(body).await;
    let client = protected_client_at(port);

    let patches = fetch_patches(&client, "o/r", 1, "deadbeef", &[])
        .await
        .expect("fetch");
    assert_eq!(patches.len(), 2);
    let paths: Vec<_> = patches.iter().map(|p| p.path.as_str()).collect();
    assert!(paths.contains(&"src/a.rs"));
    assert!(paths.contains(&"src/b.rs"));
    for patch in &patches {
        assert_eq!(patch.served_by, ReviewFileServedBy::GithubRest);
        assert_eq!(patch.head_ref_oid, "deadbeef");
    }
    let added = patches.iter().find(|p| p.path == "src/b.rs").expect("b");
    assert_eq!(added.status, ReviewFileChangeType::Added);
    assert_eq!(added.additions, 2);
    assert_eq!(added.deletions, 0);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fetch_patches_path_filter_drops_unrequested_files() {
    let _budget_guard = crate::github_api::acquire_global_budget_test_lock().await;
    use serde_json::json;
    let body = json!([
        {
            "sha": "aaa", "filename": "want.rs", "status": "modified",
            "additions": 1, "deletions": 0, "changes": 1,
            "blob_url": "https://example.com/x", "raw_url": "https://example.com/x",
            "contents_url": "https://example.com/x",
            "patch": "@@ -1 +1 @@\n-a\n+A\n"
        },
        {
            "sha": "bbb", "filename": "skip.rs", "status": "modified",
            "additions": 1, "deletions": 0, "changes": 1,
            "blob_url": "https://example.com/y", "raw_url": "https://example.com/y",
            "contents_url": "https://example.com/y",
            "patch": "@@ -1 +1 @@\n-b\n+B\n"
        }
    ]);
    let (port, server) = spawn_mock_pulls_files(body).await;
    let client = protected_client_at(port);

    let patches = fetch_patches(&client, "o/r", 1, "head", &["want.rs".to_string()])
        .await
        .expect("fetch");
    assert_eq!(patches.len(), 1);
    assert_eq!(patches[0].path, "want.rs");
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fetch_patches_stops_paging_when_requested_path_is_found() {
    let _budget_guard = crate::github_api::acquire_global_budget_test_lock().await;
    use axum::Router;
    use axum::extract::Query;
    use axum::http::HeaderValue;
    use axum::response::IntoResponse;
    use axum::routing::get;
    use serde::Deserialize;
    use serde_json::json;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::net::TcpListener;

    #[derive(Deserialize)]
    struct PageQuery {
        page: Option<u8>,
    }

    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let calls = Arc::new(AtomicUsize::new(0));
    let route_calls = Arc::clone(&calls);
    let app = Router::new().route(
        "/repos/{owner}/{repo}/pulls/{number}/files",
        get(move |Query(query): Query<PageQuery>| {
            let calls = Arc::clone(&route_calls);
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                let body = match query.page {
                    Some(2) => json!([{
                        "sha": "want", "filename": "want.rs", "status": "modified",
                        "additions": 1, "deletions": 0, "changes": 1,
                        "blob_url": "https://example.com/w",
                        "raw_url": "https://example.com/w",
                        "contents_url": "https://example.com/w",
                        "patch": "@@ -1 +1 @@\n-a\n+A\n"
                    }]),
                    _ => json!([{
                        "sha": "skip", "filename": "skip.rs", "status": "modified",
                        "additions": 1, "deletions": 0, "changes": 1,
                        "blob_url": "https://example.com/s",
                        "raw_url": "https://example.com/s",
                        "contents_url": "https://example.com/s",
                        "patch": "@@ -1 +1 @@\n-b\n+B\n"
                    }]),
                };
                let mut response = axum::Json(body).into_response();
                if query.page.is_none() || query.page == Some(2) {
                    let next_page = query.page.unwrap_or(1) + 1;
                    response.headers_mut().insert(
                        "link",
                        HeaderValue::from_str(&format!(
                            "<http://127.0.0.1:{port}/repos/o/r/pulls/1/files?page={next_page}>; rel=\"next\""
                        ))
                        .expect("link header"),
                    );
                }
                response
            }
        }),
    );
    let server = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    let client = protected_client_at(port);

    let patches = fetch_patches(&client, "o/r", 1, "head", &["want.rs".to_string()])
        .await
        .expect("fetch");
    assert_eq!(patches.len(), 1);
    assert_eq!(patches[0].path, "want.rs");
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn any_patch_matches_stops_after_matching_page() {
    let _budget_guard = crate::github_api::acquire_global_budget_test_lock().await;
    use axum::Router;
    use axum::extract::Query;
    use axum::http::HeaderValue;
    use axum::response::IntoResponse;
    use axum::routing::get;
    use serde::Deserialize;
    use serde_json::json;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::net::TcpListener;

    #[derive(Deserialize)]
    struct PageQuery {
        page: Option<u8>,
    }

    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let calls = Arc::new(AtomicUsize::new(0));
    let route_calls = Arc::clone(&calls);
    let app = Router::new().route(
        "/repos/{owner}/{repo}/pulls/{number}/files",
        get(move |Query(query): Query<PageQuery>| {
            let calls = Arc::clone(&route_calls);
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                let body = match query.page {
                    Some(2) => json!([{
                        "sha": "match", "filename": "match.rs", "status": "modified",
                        "additions": 1, "deletions": 0, "changes": 1,
                        "blob_url": "https://example.com/m",
                        "raw_url": "https://example.com/m",
                        "contents_url": "https://example.com/m",
                        "patch": "@@ -1 +1 @@\n+<<<<<<< HEAD\n"
                    }]),
                    _ => json!([{
                        "sha": "skip", "filename": "skip.rs", "status": "modified",
                        "additions": 1, "deletions": 0, "changes": 1,
                        "blob_url": "https://example.com/s",
                        "raw_url": "https://example.com/s",
                        "contents_url": "https://example.com/s",
                        "patch": "@@ -1 +1 @@\n+clean\n"
                    }]),
                };
                let mut response = axum::Json(body).into_response();
                if query.page.is_none() || query.page == Some(2) {
                    let next_page = query.page.unwrap_or(1) + 1;
                    response.headers_mut().insert(
                        "link",
                        HeaderValue::from_str(&format!(
                            "<http://127.0.0.1:{port}/repos/o/r/pulls/1/files?page={next_page}>; rel=\"next\""
                        ))
                        .expect("link header"),
                    );
                }
                response
            }
        }),
    );
    let server = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    let client = protected_client_at(port);

    let matched = any_patch_matches(&client, "o/r", 1, |patch| patch.contains("<<<<<<<"))
        .await
        .expect("scan");
    assert!(matched);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fetch_patches_rejects_malformed_repo_full_name_at_runtime() {
    let _budget_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let (port, server) = spawn_mock_pulls_files(serde_json::json!([])).await;
    let client = protected_client_at(port);
    let err = fetch_patches(&client, "no-slash", 1, "head", &[])
        .await
        .unwrap_err();
    assert!(matches!(err, RestFetchError::InvalidRequest(_)));
    server.abort();
}

#[test]
fn fetch_patches_rejects_malformed_repo_full_name() {
    assert!(split_repo_full_name("no-slash").is_none());
    assert!(split_repo_full_name("").is_none());
    assert!(split_repo_full_name("/repo").is_none());
    assert!(split_repo_full_name("owner/").is_none());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fetch_patches_conditional_returns_etag_from_response_header() {
    let _budget_guard = crate::github_api::acquire_global_budget_test_lock().await;
    use axum::Router;
    use axum::http::HeaderValue;
    use axum::response::IntoResponse;
    use axum::routing::get;
    use serde_json::json;
    use tokio::net::TcpListener;

    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let app = Router::new().route(
        "/repos/{owner}/{repo}/pulls/{number}/files",
        get(|| async {
            let body = json!([
                {
                    "sha": "a11", "filename": "src/a.rs", "status": "modified",
                    "additions": 1, "deletions": 0, "changes": 1,
                    "blob_url": "https://example.com/a", "raw_url": "https://example.com/a",
                    "contents_url": "https://example.com/a",
                    "patch": "@@ -1 +1 @@\n-a\n+A\n"
                }
            ]);
            let mut response = axum::Json(body).into_response();
            response
                .headers_mut()
                .insert("etag", HeaderValue::from_static("W/\"abc-123\""));
            response
        }),
    );
    let server = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    let client = protected_client_at(port);

    let outcome = fetch_patches_conditional(&client, "o/r", 1, "head", &[], None)
        .await
        .expect("conditional");
    match outcome {
        ConditionalFetchOutcome::Fetched { etag, patches } => {
            assert_eq!(etag.as_deref(), Some("W/\"abc-123\""));
            assert_eq!(patches.len(), 1);
            assert_eq!(patches[0].etag.as_deref(), Some("W/\"abc-123\""));
        }
        ConditionalFetchOutcome::NotModified => panic!("expected Fetched, got NotModified"),
    }
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fetch_patches_conditional_returns_not_modified_on_304() {
    let _budget_guard = crate::github_api::acquire_global_budget_test_lock().await;
    use axum::Router;
    use axum::http::StatusCode;
    use axum::routing::get;
    use tokio::net::TcpListener;

    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let app = Router::new().route(
        "/repos/{owner}/{repo}/pulls/{number}/files",
        get(|| async { (StatusCode::NOT_MODIFIED, "") }),
    );
    let server = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    let client = protected_client_at(port);

    let outcome =
        fetch_patches_conditional(&client, "o/r", 1, "head", &[], Some("W/\"existing-etag\""))
            .await
            .expect("conditional");
    assert!(matches!(outcome, ConditionalFetchOutcome::NotModified));
    server.abort();
}
