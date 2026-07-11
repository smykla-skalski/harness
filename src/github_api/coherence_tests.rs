use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use reqwest::Method;
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::Notify;

use super::{
    GitHubCachePolicy, GitHubDataChange, GitHubPriority, GitHubProtectedClient,
    GitHubRequestDescriptor,
};

const CACHE_TTL: Duration = Duration::from_secs(60);

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn exact_reads_share_cache_across_operation_labels() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let requests = Arc::new(AtomicUsize::new(0));
    let app = Router::new().route(
        "/resource",
        get({
            let requests = Arc::clone(&requests);
            move || counted_response(Arc::clone(&requests))
        }),
    );
    let (base_url, server) = spawn_server(app).await;
    let client =
        GitHubProtectedClient::with_base_url("cross-operation-token", &base_url).expect("client");

    let first = client
        .rest_json::<Value>(
            Method::GET,
            "/resource",
            None,
            read_descriptor("reviews.resource"),
        )
        .await
        .expect("first read");
    let second = client
        .rest_json::<Value>(
            Method::GET,
            "/resource",
            None,
            read_descriptor("task_board.resource"),
        )
        .await
        .expect("second read");

    assert_eq!(first.body, second.body);
    assert!(!first.provenance.from_cache);
    assert!(second.provenance.from_cache);
    assert_eq!(requests.load(Ordering::SeqCst), 1);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn mutation_epoch_invalidates_exact_read_cache_and_publishes_change() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let requests = Arc::new(AtomicUsize::new(0));
    let app = Router::new()
        .route(
            "/resource",
            get({
                let requests = Arc::clone(&requests);
                move || counted_response(Arc::clone(&requests))
            }),
        )
        .route(
            "/mutate",
            post(|| async { Json(json!({ "updated": true })) }),
        );
    let (base_url, server) = spawn_server(app).await;
    let client =
        GitHubProtectedClient::with_base_url("mutation-epoch-token", &base_url).expect("client");
    let mut changes = GitHubProtectedClient::data_changes();
    let initial_revision = GitHubProtectedClient::data_revision();

    let first = client
        .rest_json::<Value>(
            Method::GET,
            "/resource",
            None,
            read_descriptor("reviews.before_mutation"),
        )
        .await
        .expect("initial read");
    client
        .rest_json::<Value>(
            Method::POST,
            "/mutate",
            Some(json!({ "title": "changed" })),
            mutation_descriptor("reviews.update_resource"),
        )
        .await
        .expect("mutation");
    let change = recv_change(&mut changes).await;
    let second = client
        .rest_json::<Value>(
            Method::GET,
            "/resource",
            None,
            read_descriptor("task_board.after_mutation"),
        )
        .await
        .expect("post-mutation read");

    assert_eq!(change.revision, initial_revision + 1);
    assert_eq!(change.operation, "reviews.update_resource");
    assert_eq!(GitHubProtectedClient::data_revision(), initial_revision + 1);
    assert_eq!(first.body["request"], 1);
    assert_eq!(second.body["request"], 2);
    assert_eq!(requests.load(Ordering::SeqCst), 2);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn read_started_before_mutation_cannot_repopulate_current_epoch() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let state = DelayedReadState::default();
    let app = Router::new()
        .route("/resource", get(delayed_first_response))
        .route(
            "/mutate",
            post(|| async { Json(json!({ "updated": true })) }),
        )
        .with_state(state.clone());
    let (base_url, server) = spawn_server(app).await;
    let client =
        GitHubProtectedClient::with_base_url("inflight-epoch-token", &base_url).expect("client");

    let old_read = tokio::spawn({
        let client = client.clone();
        async move {
            client
                .rest_json::<Value>(
                    Method::GET,
                    "/resource",
                    None,
                    read_descriptor("reviews.inflight"),
                )
                .await
        }
    });
    state.started.notified().await;
    client
        .rest_json::<Value>(
            Method::POST,
            "/mutate",
            None,
            mutation_descriptor("task_board.concurrent_mutation"),
        )
        .await
        .expect("mutation");
    state.release.notify_one();
    let retried = old_read.await.expect("old read join").expect("old read");

    let current = client
        .rest_json::<Value>(
            Method::GET,
            "/resource",
            None,
            read_descriptor("task_board.current"),
        )
        .await
        .expect("current read");

    assert_eq!(retried.body["request"], 2);
    assert_eq!(current.body["request"], 2);
    assert!(current.provenance.from_cache);
    assert_eq!(state.requests.load(Ordering::SeqCst), 2);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn raw_read_started_before_mutation_retries_at_current_epoch() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let state = DelayedReadState::default();
    let app = Router::new()
        .route("/resource", get(delayed_first_response))
        .route(
            "/mutate",
            post(|| async { Json(json!({ "updated": true })) }),
        )
        .with_state(state.clone());
    let (base_url, server) = spawn_server(app).await;
    let client =
        GitHubProtectedClient::with_base_url("raw-inflight-token", &base_url).expect("client");

    let old_read = tokio::spawn({
        let client = client.clone();
        async move {
            client
                .rest_json_with_headers::<Value>(
                    Method::GET,
                    "/resource",
                    None,
                    GitHubRequestDescriptor::rest_core(
                        "reviews.raw_inflight",
                        GitHubPriority::NormalRead,
                        GitHubCachePolicy::no_store(),
                    ),
                    HeaderMap::new(),
                )
                .await
        }
    });
    state.started.notified().await;
    client
        .rest_json::<Value>(
            Method::POST,
            "/mutate",
            None,
            mutation_descriptor("task_board.concurrent_raw_mutation"),
        )
        .await
        .expect("mutation");
    state.release.notify_one();
    let retried = old_read.await.expect("old read join").expect("old read");

    assert_eq!(retried.body.expect("body")["request"], 2);
    assert_eq!(state.requests.load(Ordering::SeqCst), 2);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn exact_and_raw_reads_stop_after_the_shared_stability_budget() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let requests = Arc::new(AtomicUsize::new(0));
    let app = Router::new()
        .route("/resource", get(always_mutating_response))
        .with_state(Arc::clone(&requests));
    let (base_url, server) = spawn_server(app).await;
    let client =
        GitHubProtectedClient::with_base_url("unstable-read-token", &base_url).expect("client");
    let descriptor = |operation| {
        GitHubRequestDescriptor::rest_core(
            operation,
            GitHubPriority::NormalRead,
            GitHubCachePolicy::no_store(),
        )
    };

    let exact_error = client
        .rest_json::<Value>(
            Method::GET,
            "/resource",
            None,
            descriptor("reviews.never_stable"),
        )
        .await
        .err()
        .expect("exact read must exhaust its stability budget");
    let raw_error = client
        .rest_json_with_headers::<Value>(
            Method::GET,
            "/resource",
            None,
            descriptor("task_board.never_stable"),
            HeaderMap::new(),
        )
        .await
        .err()
        .expect("raw read must exhaust its stability budget");

    assert_eq!(exact_error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(raw_error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(requests.load(Ordering::SeqCst), 6);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stable_projection_guard_blocks_mutation_until_commit_finishes() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let initial_revision = GitHubProtectedClient::data_revision();
    let projection_guard = super::stable_data_revision_guard(initial_revision)
        .await
        .expect("stable revision guard");
    let mut mutation = tokio::spawn(async {
        let mut guard = super::begin_external_mutation("mutation.after_projection").await;
        guard.mark_remote_success();
    });

    assert!(
        tokio::time::timeout(Duration::from_millis(25), &mut mutation)
            .await
            .is_err(),
        "mutation must wait for the projection commit boundary"
    );
    assert_eq!(GitHubProtectedClient::data_revision(), initial_revision);
    drop(projection_guard);
    mutation.await.expect("mutation join");
    assert_eq!(GitHubProtectedClient::data_revision(), initial_revision + 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn local_ready_event_republishes_without_advancing_revision() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let revision = GitHubProtectedClient::data_revision();
    let mut changes = GitHubProtectedClient::data_changes();

    super::republish_current_data_change("task_board.github.local_sync_ready");
    let change = recv_change(&mut changes).await;

    assert_eq!(change.revision, revision);
    assert_eq!(change.operation, "task_board.github.local_sync_ready");
    assert_eq!(GitHubProtectedClient::data_revision(), revision);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn every_mutation_entry_point_publishes_exactly_once() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let app = Router::new()
        .route(
            "/graphql",
            post(|| async { Json(json!({ "data": { "ok": true } })) }),
        )
        .route("/json", post(|| async { Json(json!({ "ok": true })) }))
        .route("/empty", post(|| async { StatusCode::NO_CONTENT }));
    let (base_url, server) = spawn_server(app).await;
    let client =
        GitHubProtectedClient::with_base_url("mutation-entry-token", &base_url).expect("client");
    let mut changes = GitHubProtectedClient::data_changes();
    let mut expected_revision = GitHubProtectedClient::data_revision();

    client
        .graphql::<Value>(
            mutation_descriptor("mutation.graphql"),
            json!({ "query": "mutation { first: __typename }" }),
        )
        .await
        .expect("graphql mutation");
    expected_revision += 1;
    assert_change(&mut changes, expected_revision, "mutation.graphql").await;

    client
        .graphql_envelope(
            mutation_descriptor("mutation.graphql_envelope"),
            json!({ "query": "mutation { second: __typename }" }),
        )
        .await
        .expect("graphql envelope mutation");
    expected_revision += 1;
    assert_change(&mut changes, expected_revision, "mutation.graphql_envelope").await;

    client
        .rest_json::<Value>(
            Method::POST,
            "/json",
            None,
            mutation_descriptor("mutation.rest_json"),
        )
        .await
        .expect("rest json mutation");
    expected_revision += 1;
    assert_change(&mut changes, expected_revision, "mutation.rest_json").await;

    client
        .rest_json_with_headers::<Value>(
            Method::POST,
            "/json",
            None,
            mutation_descriptor("mutation.rest_json_with_headers"),
            HeaderMap::new(),
        )
        .await
        .expect("rest json with headers mutation");
    expected_revision += 1;
    assert_change(
        &mut changes,
        expected_revision,
        "mutation.rest_json_with_headers",
    )
    .await;

    client
        .rest_empty(
            Method::POST,
            "/empty",
            None,
            mutation_descriptor("mutation.rest_empty"),
        )
        .await
        .expect("rest empty mutation");
    expected_revision += 1;
    assert_change(&mut changes, expected_revision, "mutation.rest_empty").await;

    let mut mutation_guard = super::begin_external_mutation("mutation.external_transport").await;
    mutation_guard.mark_remote_success();
    drop(mutation_guard);
    expected_revision += 1;
    assert_change(
        &mut changes,
        expected_revision,
        "mutation.external_transport",
    )
    .await;
    assert_eq!(GitHubProtectedClient::data_revision(), expected_revision);
    assert!(
        changes.try_recv().is_err(),
        "unexpected duplicate data change"
    );
    server.abort();
}

#[derive(Clone, Default)]
struct DelayedReadState {
    requests: Arc<AtomicUsize>,
    started: Arc<Notify>,
    release: Arc<Notify>,
}

async fn delayed_first_response(State(state): State<DelayedReadState>) -> impl IntoResponse {
    let request = state.requests.fetch_add(1, Ordering::SeqCst) + 1;
    if request == 1 {
        state.started.notify_one();
        state.release.notified().await;
    }
    Json(json!({ "request": request }))
}

async fn counted_response(requests: Arc<AtomicUsize>) -> impl IntoResponse {
    let request = requests.fetch_add(1, Ordering::SeqCst) + 1;
    Json(json!({ "request": request }))
}

async fn always_mutating_response(State(requests): State<Arc<AtomicUsize>>) -> impl IntoResponse {
    let request = requests.fetch_add(1, Ordering::SeqCst) + 1;
    let mut guard = super::begin_external_mutation("test.read_instability").await;
    guard.mark_remote_success();
    drop(guard);
    Json(json!({ "request": request }))
}

fn read_descriptor(operation: &str) -> GitHubRequestDescriptor {
    GitHubRequestDescriptor::rest_core(
        operation,
        GitHubPriority::NormalRead,
        GitHubCachePolicy::read_through(CACHE_TTL, CACHE_TTL),
    )
}

fn mutation_descriptor(operation: &str) -> GitHubRequestDescriptor {
    if operation.contains("graphql") {
        return GitHubRequestDescriptor::graphql(
            operation,
            GitHubPriority::Mutation,
            GitHubCachePolicy::no_store(),
        );
    }
    GitHubRequestDescriptor::rest_core(
        operation,
        GitHubPriority::Mutation,
        GitHubCachePolicy::no_store(),
    )
}

async fn recv_change(
    changes: &mut tokio::sync::broadcast::Receiver<GitHubDataChange>,
) -> GitHubDataChange {
    tokio::time::timeout(Duration::from_secs(1), changes.recv())
        .await
        .expect("data change timeout")
        .expect("data change")
}

async fn assert_change(
    changes: &mut tokio::sync::broadcast::Receiver<GitHubDataChange>,
    revision: u64,
    operation: &str,
) {
    let change = recv_change(changes).await;
    assert_eq!(change.revision, revision);
    assert_eq!(change.operation, operation);
}

async fn spawn_server(app: Router) -> (String, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let server = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    (format!("http://127.0.0.1:{port}"), server)
}
