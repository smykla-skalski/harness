use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use axum::Router;
use axum::extract::Query;
use axum::http::HeaderValue;
use axum::response::IntoResponse;
use axum::routing::get;
use serde::Deserialize;
use serde_json::json;
use tokio::net::TcpListener;

use super::super::fetcher::fetch_patches;
use super::protected_client_at;

#[derive(Deserialize)]
struct PageQuery {
    page: Option<u8>,
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn fetch_patches_restarts_all_pages_after_revision_change() {
    let _budget_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let calls = Arc::new(AtomicUsize::new(0));
    let revision_changed = Arc::new(AtomicBool::new(false));
    let route_calls = Arc::clone(&calls);
    let route_revision_changed = Arc::clone(&revision_changed);
    let app = Router::new().route(
        "/repos/{owner}/{repo}/pulls/{number}/files",
        get(move |Query(query): Query<PageQuery>| {
            let calls = Arc::clone(&route_calls);
            let revision_changed = Arc::clone(&route_revision_changed);
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                publish_change_on_second_page(&query, &revision_changed).await;
                page_response(port, &query, revision_changed.load(Ordering::SeqCst))
            }
        }),
    );
    let server = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    let client = protected_client_at(port);

    let patches = fetch_patches(&client, "o/r", 1, "head", &[])
        .await
        .expect("fetch");

    assert_eq!(patches.len(), 2);
    assert!(patches.iter().all(|patch| patch.path.starts_with("new-")));
    assert!(calls.load(Ordering::SeqCst) >= 4);
    server.abort();
}

async fn publish_change_on_second_page(query: &PageQuery, revision_changed: &AtomicBool) {
    if query.page == Some(2) && !revision_changed.swap(true, Ordering::SeqCst) {
        let mut guard =
            crate::github_api::begin_external_mutation("test.patch_pagination_change").await;
        guard.mark_remote_success();
        drop(guard);
    }
}

fn page_response(port: u16, query: &PageQuery, revision_changed: bool) -> axum::response::Response {
    let epoch = if revision_changed { "new" } else { "old" };
    let page = query.page.unwrap_or(1);
    let mut response = axum::Json(json!([{
        "sha": format!("{epoch}-{page}"),
        "filename": format!("{epoch}-page-{page}.rs"),
        "status": "modified",
        "additions": 1,
        "deletions": 0,
        "changes": 1,
        "patch": "+changed"
    }]))
    .into_response();
    if query.page.is_none() {
        response.headers_mut().insert(
            "link",
            HeaderValue::from_str(&format!(
                "<http://127.0.0.1:{port}/repos/o/r/pulls/1/files?page=2>; rel=\"next\""
            ))
            .expect("link header"),
        );
    }
    response
}
