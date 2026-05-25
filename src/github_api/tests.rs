use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, SystemTime};

use axum::http::{HeaderMap, HeaderValue};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use reqwest::Method;
use serde_json::{Value, json};
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
async fn rest_rate_limit_headers_update_bucket_status() {
    let budget = GitHubRateBudget::new();
    let mut headers = HeaderMap::new();
    headers.insert("x-ratelimit-resource", HeaderValue::from_static("search"));
    headers.insert("x-ratelimit-remaining", HeaderValue::from_static("4"));
    headers.insert("x-ratelimit-limit", HeaderValue::from_static("30"));
    headers.insert("x-ratelimit-used", HeaderValue::from_static("26"));
    headers.insert("x-ratelimit-reset", HeaderValue::from_static("4070908800"));

    let snapshot = budget
        .observe_headers(&headers)
        .await
        .expect("headers parse");
    let statuses = budget.bucket_statuses().await;

    assert_eq!(snapshot.resource, GitHubRateResource::Search);
    assert_eq!(snapshot.remaining, 4);
    assert!(
        statuses
            .iter()
            .any(|bucket| bucket.resource == GitHubRateResource::Search
                && bucket.limit == 30
                && bucket.used == 26),
        "search bucket should reflect REST headers: {statuses:?}"
    );
}

#[tokio::test]
async fn secondary_retry_after_cools_matching_resource() {
    let budget = GitHubRateBudget::new();
    budget
        .observe_secondary_limit(GitHubRateResource::Core, Some(Duration::from_secs(42)))
        .await;
    let descriptor = GitHubRequestDescriptor::rest_core(
        "github_api.tests.cooldown",
        GitHubPriority::FreshRead,
        GitHubCachePolicy::no_store(),
    );

    let error = budget
        .acquire_for(&descriptor)
        .await
        .expect_err("cooldown should reject acquire");

    assert_eq!(error.resource, GitHubRateResource::Core);
    assert_eq!(error.reason, "secondary_rate_limit");
    assert!(error.retry_after <= Duration::from_secs(42));
    assert!(error.retry_after > Duration::from_secs(35));
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

#[test]
fn disk_cache_writes_valid_json_without_tmp_file() {
    let temp = tempfile::tempdir().expect("tempdir");
    let cache = GitHubCache::test_with_root(temp.path().to_path_buf());
    let key = GitHubCache::key(&["disk", "atomic"]);
    let policy = GitHubCachePolicy::read_through(Duration::from_secs(60), Duration::from_secs(60));

    cache.store(
        &key,
        &json!({ "ok": true }),
        Some("\"etag\"".to_string()),
        policy,
    );

    let path = disk_cache_path(temp.path(), &key);
    let raw = fs_err::read_to_string(&path).expect("cache file");
    let parsed: Value = serde_json::from_str(&raw).expect("valid json");
    assert_eq!(parsed["body"]["ok"], true);
    assert_no_tmp_cache_files(temp.path());
}

#[test]
fn disk_cache_gc_prunes_oldest_entries() {
    let temp = tempfile::tempdir().expect("tempdir");
    let cache = GitHubCache::test_with_root(temp.path().to_path_buf());
    let policy = GitHubCachePolicy::read_through(Duration::from_secs(60), Duration::from_secs(60));

    for index in 0..20 {
        let key = GitHubCache::key(&["disk", "gc", &index.to_string()]);
        cache.store(&key, &json!({ "index": index }), None, policy);
    }

    let count = count_cache_json_files(temp.path());
    assert!(
        count <= 16,
        "disk cache should prune when over the test GC cap, found {count}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn read_only_calls_return_stale_cache_when_budget_is_deferred() {
    let requests = Arc::new(AtomicUsize::new(0));
    let app = Router::new().route(
        "/cached",
        get({
            let requests = Arc::clone(&requests);
            move || cached_rest_response(Arc::clone(&requests))
        }),
    );
    let (base_url, server) = spawn_server(app).await;
    let client = GitHubProtectedClient::with_base_url("test-token", &base_url).expect("client");
    let first_descriptor = GitHubRequestDescriptor::rest_core(
        "github_api.tests.stale_fallback",
        GitHubPriority::NormalRead,
        GitHubCachePolicy::read_through(Duration::ZERO, Duration::from_secs(60)),
    );
    let descriptor = GitHubRequestDescriptor {
        cache_policy: GitHubCachePolicy {
            force_refresh: true,
            ..first_descriptor.cache_policy
        },
        ..first_descriptor.clone()
    };

    let first = client
        .rest_json::<Value>(Method::GET, "/cached", None, first_descriptor)
        .await
        .expect("first network response");
    tokio::time::sleep(Duration::from_millis(5)).await;
    let second = client
        .rest_json::<Value>(Method::GET, "/cached", None, descriptor)
        .await
        .expect("stale fallback");

    assert_eq!(first.body["request"], 1);
    assert_eq!(second.body["request"], 1);
    assert!(second.provenance.from_cache);
    assert_eq!(
        second.provenance.cache_state,
        super::types::GitHubResponseCacheState::Deferred
    );
    assert_eq!(requests.load(Ordering::SeqCst), 1);
    server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn identical_cacheable_reads_share_single_inflight_request() {
    let requests = Arc::new(AtomicUsize::new(0));
    let app = Router::new().route(
        "/singleflight",
        get({
            let requests = Arc::clone(&requests);
            move || delayed_rest_response(Arc::clone(&requests))
        }),
    );
    let (base_url, server) = spawn_server(app).await;
    let client = GitHubProtectedClient::with_base_url("test-token", &base_url).expect("client");
    let descriptor = GitHubRequestDescriptor::rest_core(
        "github_api.tests.singleflight",
        GitHubPriority::FreshRead,
        GitHubCachePolicy::read_through(Duration::from_secs(60), Duration::from_secs(60)),
    );
    let descriptor = GitHubRequestDescriptor {
        resource: GitHubRateResource::Search,
        ..descriptor
    };

    let mut tasks = Vec::new();
    for _ in 0..5 {
        let client = client.clone();
        let descriptor = descriptor.clone();
        tasks.push(tokio::spawn(async move {
            client
                .rest_json::<Value>(Method::GET, "/singleflight", None, descriptor)
                .await
        }));
    }
    for task in tasks {
        task.await.expect("join").expect("request should succeed");
    }

    assert_eq!(requests.load(Ordering::SeqCst), 1);
    server.abort();
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

async fn spawn_server(app: Router) -> (String, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("addr").port();
    let server = tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    (format!("http://127.0.0.1:{port}"), server)
}

async fn cached_rest_response(requests: Arc<AtomicUsize>) -> impl IntoResponse {
    let count = requests.fetch_add(1, Ordering::SeqCst) + 1;
    (
        [
            ("x-ratelimit-resource", "core"),
            ("x-ratelimit-remaining", "500"),
            ("x-ratelimit-limit", "5000"),
            ("x-ratelimit-used", "4500"),
            ("x-ratelimit-reset", "4070908800"),
        ],
        Json(json!({ "request": count })),
    )
}

async fn delayed_rest_response(requests: Arc<AtomicUsize>) -> impl IntoResponse {
    tokio::time::sleep(Duration::from_millis(25)).await;
    let count = requests.fetch_add(1, Ordering::SeqCst) + 1;
    (
        [
            ("x-ratelimit-resource", "core"),
            ("x-ratelimit-remaining", "4999"),
            ("x-ratelimit-limit", "5000"),
            ("x-ratelimit-used", "1"),
            ("x-ratelimit-reset", "4070908800"),
        ],
        Json(json!({ "request": count })),
    )
}

fn disk_cache_path(root: &std::path::Path, key: &str) -> std::path::PathBuf {
    root.join("github-cache")
        .join("v1")
        .join(&key[..2])
        .join(format!("{key}.json"))
}

fn count_cache_json_files(root: &std::path::Path) -> usize {
    let cache_root = root.join("github-cache").join("v1");
    let Ok(entries) = fs_err::read_dir(cache_root) else {
        return 0;
    };
    entries
        .flatten()
        .filter_map(|entry| fs_err::read_dir(entry.path()).ok())
        .flat_map(|children| children.flatten())
        .filter(|child| child.path().extension().and_then(|ext| ext.to_str()) == Some("json"))
        .count()
}

fn assert_no_tmp_cache_files(root: &std::path::Path) {
    let cache_root = root.join("github-cache").join("v1");
    let Ok(entries) = fs_err::read_dir(cache_root) else {
        return;
    };
    for dir in entries.flatten() {
        let Ok(children) = fs_err::read_dir(dir.path()) else {
            continue;
        };
        for child in children.flatten() {
            assert_ne!(
                child.path().extension().and_then(|ext| ext.to_str()),
                Some("tmp"),
                "temporary cache file should have been atomically renamed"
            );
        }
    }
}
