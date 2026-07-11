use std::time::Duration;

use axum::http::{HeaderMap, StatusCode};
use std::sync::Arc;

use axum::extract::State;
use axum::routing::post;
use axum::{Json, Router};
use reqwest::Method;
use serde_json::{Value, json};
use tokio::net::TcpListener;
use tokio::sync::Notify;

use super::{
    GitHubCachePolicy, GitHubDataChange, GitHubPriority, GitHubProtectedClient,
    GitHubRequestDescriptor,
};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn successful_mutations_publish_even_when_local_decoding_fails() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let app = Router::new()
        .route(
            "/graphql",
            post(|| async { Json(json!({ "data": { "updated": true } })) }),
        )
        .route("/json", post(|| async { Json(json!({ "updated": true })) }));
    let (base_url, server) = spawn_server(app).await;
    let client = GitHubProtectedClient::with_base_url("decode-failure-token", &base_url)
        .expect("protected client");
    let mut changes = GitHubProtectedClient::data_changes();
    let mut expected_revision = GitHubProtectedClient::data_revision();

    assert!(
        client
            .graphql::<Vec<Value>>(
                mutation_descriptor("mutation.graphql_decode_failure"),
                json!({ "query": "mutation { update: __typename }" }),
            )
            .await
            .is_err(),
        "typed GraphQL decoding should fail"
    );
    expected_revision += 1;
    assert_change(
        &mut changes,
        expected_revision,
        "mutation.graphql_decode_failure",
    )
    .await;

    assert!(
        client
            .rest_json::<Vec<Value>>(
                Method::POST,
                "/json",
                None,
                mutation_descriptor("mutation.rest_decode_failure"),
            )
            .await
            .is_err(),
        "typed REST decoding should fail"
    );
    expected_revision += 1;
    assert_change(
        &mut changes,
        expected_revision,
        "mutation.rest_decode_failure",
    )
    .await;

    assert!(
        client
            .rest_json_with_headers::<Vec<Value>>(
                Method::POST,
                "/json",
                None,
                mutation_descriptor("mutation.raw_decode_failure"),
                HeaderMap::new(),
            )
            .await
            .is_err(),
        "raw REST decoding should fail"
    );
    expected_revision += 1;
    assert_change(
        &mut changes,
        expected_revision,
        "mutation.raw_decode_failure",
    )
    .await;

    assert_eq!(GitHubProtectedClient::data_revision(), expected_revision);
    assert!(
        changes.try_recv().is_err(),
        "mutation published more than once"
    );
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_successful_graphql_response_still_publishes_mutation() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let app = Router::new().route(
        "/graphql",
        post(|| async { (StatusCode::OK, "{malformed-json") }),
    );
    let (base_url, server) = spawn_server(app).await;
    let client = GitHubProtectedClient::with_base_url("malformed-graphql-token", &base_url)
        .expect("protected client");
    let mut changes = GitHubProtectedClient::data_changes();
    let initial_revision = GitHubProtectedClient::data_revision();

    assert!(
        client
            .graphql_envelope(
                mutation_descriptor("mutation.graphql_malformed_success"),
                json!({ "query": "mutation { update: __typename }" }),
            )
            .await
            .is_err(),
        "malformed GraphQL response"
    );

    assert_change(
        &mut changes,
        initial_revision + 1,
        "mutation.graphql_malformed_success",
    )
    .await;
    assert!(
        changes.try_recv().is_err(),
        "mutation published more than once"
    );
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn partial_graphql_data_with_errors_still_publishes_mutation() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let app = Router::new().route(
        "/graphql",
        post(|| async {
            Json(json!({
                "data": { "updated": true },
                "errors": [{ "message": "another field failed" }],
            }))
        }),
    );
    let (base_url, server) = spawn_server(app).await;
    let client = GitHubProtectedClient::with_base_url("partial-graphql-token", &base_url)
        .expect("protected client");
    let mut changes = GitHubProtectedClient::data_changes();
    let initial_revision = GitHubProtectedClient::data_revision();

    assert!(
        client
            .graphql_envelope(
                mutation_descriptor("mutation.graphql_partial_success"),
                json!({ "query": "mutation { firstMutation secondMutation }" }),
            )
            .await
            .is_err(),
        "partial GraphQL response reports an error"
    );

    assert_change(
        &mut changes,
        initial_revision + 1,
        "mutation.graphql_partial_success",
    )
    .await;
    assert!(
        changes.try_recv().is_err(),
        "mutation published more than once"
    );
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn cancelled_http_waiter_leaves_mutation_owned_by_detached_request() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let state = DelayedMutationState::default();
    let app = Router::new()
        .route("/mutate", post(delayed_mutation_response))
        .with_state(state.clone());
    let (base_url, server) = spawn_server(app).await;
    let client = GitHubProtectedClient::with_base_url("cancelled-http-token", &base_url)
        .expect("protected client");
    let mut changes = GitHubProtectedClient::data_changes();
    let initial_revision = GitHubProtectedClient::data_revision();

    let mutation = tokio::spawn(async move {
        client
            .rest_json::<Value>(
                Method::POST,
                "/mutate",
                None,
                mutation_descriptor("mutation.cancelled_http_waiter"),
            )
            .await
    });
    state.started.notified().await;
    mutation.abort();
    let cancelled = match mutation.await {
        Err(error) => error,
        Ok(_) => panic!("mutation waiter was not cancelled"),
    };
    assert!(cancelled.is_cancelled());

    assert!(
        tokio::time::timeout(
            Duration::from_millis(25),
            super::stable_data_revision_guard(initial_revision),
        )
        .await
        .is_err(),
        "the detached request must retain the mutation barrier"
    );
    state.release.notify_one();

    assert_change(
        &mut changes,
        initial_revision + 1,
        "mutation.cancelled_http_waiter",
    )
    .await;
    assert!(
        changes.try_recv().is_err(),
        "mutation published more than once"
    );
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn definite_remote_failures_do_not_publish_mutations() {
    let _budget_guard = super::acquire_global_budget_test_lock().await;
    let app = Router::new()
        .route(
            "/graphql",
            post(|| async { Json(json!({ "errors": [{ "message": "denied" }] })) }),
        )
        .route(
            "/failure",
            post(|| async {
                (
                    StatusCode::UNPROCESSABLE_ENTITY,
                    Json(json!({ "message": "denied" })),
                )
            }),
        );
    let (base_url, server) = spawn_server(app).await;
    let client = GitHubProtectedClient::with_base_url("remote-failure-token", &base_url)
        .expect("protected client");
    let mut changes = GitHubProtectedClient::data_changes();
    let initial_revision = GitHubProtectedClient::data_revision();

    assert!(
        client
            .graphql_envelope(
                mutation_descriptor("mutation.graphql_rejected"),
                json!({ "query": "mutation { rejected: __typename }" }),
            )
            .await
            .is_err(),
        "GraphQL rejection"
    );
    assert!(
        client
            .rest_json::<Value>(
                Method::POST,
                "/failure",
                None,
                mutation_descriptor("mutation.rest_rejected"),
            )
            .await
            .is_err(),
        "REST rejection"
    );

    assert_eq!(GitHubProtectedClient::data_revision(), initial_revision);
    assert!(changes.try_recv().is_err(), "remote failure published");
    server.abort();
}

#[derive(Clone, Default)]
struct DelayedMutationState {
    started: Arc<Notify>,
    release: Arc<Notify>,
}

async fn delayed_mutation_response(State(state): State<DelayedMutationState>) -> Json<Value> {
    state.started.notify_one();
    state.release.notified().await;
    Json(json!({ "updated": true }))
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

async fn assert_change(
    changes: &mut tokio::sync::broadcast::Receiver<GitHubDataChange>,
    revision: u64,
    operation: &str,
) {
    let change = tokio::time::timeout(Duration::from_secs(1), changes.recv())
        .await
        .expect("data change timeout")
        .expect("data change");
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
