use std::time::{Duration, SystemTime};

use axum::Router;
use axum::http::HeaderValue;
use axum::response::IntoResponse;
use axum::routing::post;
use reqwest::header::HeaderMap;
use serde_json::json;
use tokio::net::TcpListener;

use super::budget::{GitHubRateResource, parse_retry_after};
use super::{
    GitHubCache, GitHubCachePolicy, GitHubPriority, GitHubProtectedClient, GitHubRateBudget,
    GitHubRequestDescriptor,
};

#[test]
fn cache_key_hashes_secret_material() {
    let key = GitHubCache::key(&["token", "ghp_secret"]);

    assert!(!key.contains("ghp_secret"));
    assert_eq!(key.len(), 64);
}

#[test]
fn retry_after_header_parses_seconds() {
    let mut headers = HeaderMap::new();
    headers.insert(reqwest::header::RETRY_AFTER, HeaderValue::from_static("42"));

    assert_eq!(parse_retry_after(&headers), Some(Duration::from_secs(42)));
}

#[tokio::test]
async fn budget_rejects_reads_that_would_cross_reserve_floor() {
    let budget = GitHubRateBudget::new();
    budget
        .observe_graphql_rate_limit(750, 5_000, 1, SystemTime::now() + Duration::from_secs(60))
        .await;

    let descriptor = GitHubRequestDescriptor::graphql(
        "github_api.tests.reserve_floor",
        GitHubPriority::NormalRead,
        GitHubCachePolicy::no_store(),
    );

    let error = budget
        .acquire_for(&descriptor)
        .await
        .expect_err("reserve floor should reject normal reads");

    assert_eq!(error.resource, GitHubRateResource::Graphql);
    assert_eq!(error.reason, "reserve_floor");
}

#[tokio::test]
async fn budget_prediction_uses_observed_cost_for_future_admission() {
    let budget = GitHubRateBudget::new();
    let descriptor = GitHubRequestDescriptor::graphql(
        "github_api.tests.expensive_graphql",
        GitHubPriority::NormalRead,
        GitHubCachePolicy::no_store(),
    );
    budget
        .observe_graphql_rate_limit(800, 5_000, 1, SystemTime::now() + Duration::from_secs(60))
        .await;
    budget.observe_operation_cost(&descriptor, 75).await;

    let error = budget
        .acquire_for(&descriptor)
        .await
        .expect_err("observed cost should protect reserve floor");

    assert_eq!(error.resource, GitHubRateResource::Graphql);
    assert_eq!(error.reason, "reserve_floor");
}

#[tokio::test]
async fn budget_reserves_inflight_predicted_cost_until_permit_drops() {
    let budget = GitHubRateBudget::new();
    let descriptor = GitHubRequestDescriptor::graphql(
        "github_api.tests.reserve_cost",
        GitHubPriority::NormalRead,
        GitHubCachePolicy::no_store(),
    )
    .with_expected_cost(7);
    budget
        .observe_graphql_rate_limit(764, 5_000, 1, SystemTime::now() + Duration::from_secs(60))
        .await;

    let permit = budget
        .acquire_for(&descriptor)
        .await
        .expect("first acquire stays above reserve floor");

    assert_eq!(budget.reserved_cost_for(GitHubRateResource::Graphql), 7);
    drop(permit);
    assert_eq!(budget.reserved_cost_for(GitHubRateResource::Graphql), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn graphql_rate_limit_cost_updates_status() {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let app = Router::new().route(
        "/graphql",
        post(|| async {
            axum::Json(json!({
                "data": {
                    "viewer": { "login": "octo" },
                    "rateLimit": {
                        "cost": 9,
                        "remaining": 4_991,
                        "limit": 5_000,
                        "resetAt": "2099-01-01T00:00:00Z"
                    }
                }
            }))
            .into_response()
        }),
    );
    let server = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    let client =
        GitHubProtectedClient::with_base_url("test-token", &format!("http://127.0.0.1:{port}"))
            .expect("client");

    let response = client
        .graphql_envelope(
            GitHubRequestDescriptor::graphql(
                "github_api.tests.graphql_cost",
                GitHubPriority::NormalRead,
                GitHubCachePolicy::no_store(),
            ),
            json!({ "query": "query { viewer { login } rateLimit { cost remaining limit resetAt } }" }),
        )
        .await
        .expect("graphql");

    assert_eq!(
        response
            .body
            .pointer("/data/viewer/login")
            .and_then(|v| v.as_str()),
        Some("octo")
    );
    let status = GitHubProtectedClient::status().await;
    assert!(
        status
            .buckets
            .iter()
            .any(|bucket| bucket.resource == GitHubRateResource::Graphql
                && bucket.remaining == 4_991),
        "graphql bucket should reflect response rateLimit: {status:?}"
    );
    assert!(
        status
            .top_operations
            .iter()
            .any(
                |operation| operation.operation == "github_api.tests.graphql_cost"
                    && operation.graphql_points >= 9
            ),
        "graphql operation spend should include observed cost: {status:?}"
    );
    server.abort();
}
