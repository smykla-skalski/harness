use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::Router;
use axum::extract::Query;
use axum::http::HeaderValue;
use axum::response::IntoResponse;
use axum::routing::get;
use serde::Deserialize;
use serde_json::json;
use tokio::net::TcpListener;

use super::super::fetcher::{RestFetchError, any_patch_matches};
use super::protected_client_at;

#[derive(Deserialize)]
struct PageQuery {
    page: Option<u32>,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn any_patch_matches_stops_after_matching_page() {
    let _budget_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let (port, server, calls) = spawn_scanner_pages(true).await;
    let client = protected_client_at(port);

    let matched = any_patch_matches(&client, "o/r", 1, |patch| patch.contains("<<<<<<<"))
        .await
        .expect("scan");
    assert!(matched);
    assert_eq!(calls.load(Ordering::SeqCst), 2);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn any_patch_matches_errors_when_page_cap_hides_later_pages() {
    let _budget_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let (port, server, calls) = spawn_scanner_pages(false).await;
    let client = protected_client_at(port);

    let err = any_patch_matches(&client, "o/r", 1, |patch| patch.contains("<<<<<<<"))
        .await
        .unwrap_err();
    assert!(matches!(
        err,
        RestFetchError::Http(message) if message.contains("page cap")
    ));
    assert_eq!(
        calls.load(Ordering::SeqCst),
        crate::reviews::files::FILES_PAGE_CAP as usize
    );
    server.abort();
}

async fn spawn_scanner_pages(
    include_second_page_match: bool,
) -> (u16, tokio::task::JoinHandle<()>, Arc<AtomicUsize>) {
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
                let body = scanner_page_body(include_second_page_match, query.page);
                let mut response = axum::Json(body).into_response();
                insert_next_link(&mut response, port, query.page);
                response
            }
        }),
    );
    let server = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    (port, server, calls)
}

fn scanner_page_body(include_second_page_match: bool, page: Option<u32>) -> serde_json::Value {
    if include_second_page_match && page == Some(2) {
        return json!([{
            "sha": "match", "filename": "match.rs", "status": "modified",
            "additions": 1, "deletions": 0, "changes": 1,
            "blob_url": "https://example.com/m",
            "raw_url": "https://example.com/m",
            "contents_url": "https://example.com/m",
            "patch": "@@ -1 +1 @@\n+<<<<<<< HEAD\n"
        }]);
    }
    json!([{
        "sha": "clean", "filename": "clean.rs", "status": "modified",
        "additions": 1, "deletions": 0, "changes": 1,
        "blob_url": "https://example.com/c",
        "raw_url": "https://example.com/c",
        "contents_url": "https://example.com/c",
        "patch": "@@ -1 +1 @@\n+clean\n"
    }])
}

fn insert_next_link(response: &mut axum::response::Response, port: u16, page: Option<u32>) {
    let next_page = page.unwrap_or(1) + 1;
    response.headers_mut().insert(
        "link",
        HeaderValue::from_str(&format!(
            "<http://127.0.0.1:{port}/repos/o/r/pulls/1/files?page={next_page}>; rel=\"next\""
        ))
        .expect("link header"),
    );
}
