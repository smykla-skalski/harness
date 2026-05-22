use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use reqwest::header::HeaderMap;
use tokio::sync::Barrier;

use super::{
    CoolingReason, DEFAULT_CONCURRENCY_CAP, DEFAULT_RESERVE_FLOOR, GithubRateBudget,
    GraphqlRateLimit, RateLimitResource,
};

fn headers(pairs: &[(&str, &str)]) -> HeaderMap {
    let mut map = HeaderMap::new();
    for (name, value) in pairs {
        map.insert(
            reqwest::header::HeaderName::from_bytes(name.as_bytes()).unwrap(),
            value.parse().unwrap(),
        );
    }
    map
}

fn future_epoch_seconds(secs: u64) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    (now + secs).to_string()
}

#[tokio::test]
async fn parses_x_ratelimit_headers() {
    let budget = GithubRateBudget::new(4, 50);
    let reset = future_epoch_seconds(3600);
    let map = headers(&[
        ("x-ratelimit-resource", "core"),
        ("x-ratelimit-limit", "5000"),
        ("x-ratelimit-remaining", "4321"),
        ("x-ratelimit-used", "679"),
        ("x-ratelimit-reset", reset.as_str()),
    ]);

    budget.observe_response(&map).await;
    let state = budget
        .current_state(RateLimitResource::Core)
        .await
        .expect("state recorded");
    assert_eq!(state.remaining, 4321);
    assert_eq!(state.limit, 5000);
    assert_eq!(state.used, 679);
}

#[tokio::test]
async fn defaults_resource_to_core_when_header_missing() {
    let budget = GithubRateBudget::new(4, 50);
    let map = headers(&[
        ("x-ratelimit-limit", "100"),
        ("x-ratelimit-remaining", "75"),
        ("x-ratelimit-reset", future_epoch_seconds(60).as_str()),
    ]);
    budget.observe_response(&map).await;
    assert!(
        budget
            .current_state(RateLimitResource::Core)
            .await
            .is_some()
    );
    assert!(
        budget
            .current_state(RateLimitResource::Graphql)
            .await
            .is_none()
    );
}

#[tokio::test]
async fn observe_response_without_remaining_header_is_noop() {
    let budget = GithubRateBudget::new(4, 50);
    let map = headers(&[("x-ratelimit-resource", "core")]);
    budget.observe_response(&map).await;
    assert!(
        budget
            .current_state(RateLimitResource::Core)
            .await
            .is_none()
    );
}

#[tokio::test]
async fn parses_graphql_ratelimit_node() {
    let budget = GithubRateBudget::new(4, 50);
    budget
        .observe_graphql_rate_limit(GraphqlRateLimit {
            remaining: 4990,
            limit: 5000,
            cost: 10,
            reset_at: SystemTime::now() + Duration::from_secs(900),
        })
        .await;
    let state = budget
        .current_state(RateLimitResource::Graphql)
        .await
        .expect("graphql state recorded");
    assert_eq!(state.remaining, 4990);
    assert_eq!(state.limit, 5000);
    assert_eq!(state.used, 10);
}

#[tokio::test]
async fn secondary_limit_with_retry_after_blocks_acquires() {
    let budget = GithubRateBudget::new(4, 50);
    budget
        .observe_secondary_limit(RateLimitResource::Core, Some(Duration::from_secs(2)))
        .await;
    let err = budget
        .acquire(RateLimitResource::Core, 1)
        .await
        .expect_err("acquire blocked while cooling");
    assert_eq!(err.reason, CoolingReason::SecondaryRateLimit);
    assert_eq!(err.resource, RateLimitResource::Core);
    assert!(err.until > Instant::now());
}

#[tokio::test]
async fn secondary_limit_unrelated_resource_does_not_block() {
    let budget = GithubRateBudget::new(4, 50);
    budget
        .observe_secondary_limit(RateLimitResource::Search, Some(Duration::from_secs(60)))
        .await;
    let guard = budget.acquire(RateLimitResource::Core, 1).await;
    assert!(guard.is_ok());
}

#[tokio::test]
async fn reserve_floor_defers_calls_under_threshold() {
    let budget = GithubRateBudget::new(4, 50);
    let reset = future_epoch_seconds(120);
    budget
        .observe_response(&headers(&[
            ("x-ratelimit-resource", "core"),
            ("x-ratelimit-limit", "100"),
            ("x-ratelimit-remaining", "60"),
            ("x-ratelimit-reset", reset.as_str()),
        ]))
        .await;
    let err = budget
        .acquire(RateLimitResource::Core, 25)
        .await
        .expect_err("acquire blocked by reserve floor");
    assert_eq!(err.reason, CoolingReason::ReserveFloor);
    // The cooling entry must persist - a second acquire sees the same block
    let again = budget.acquire(RateLimitResource::Core, 1).await;
    assert!(again.is_err());
}

#[tokio::test]
async fn reserve_floor_passes_when_above_threshold() {
    let budget = GithubRateBudget::new(4, 50);
    let reset = future_epoch_seconds(120);
    budget
        .observe_response(&headers(&[
            ("x-ratelimit-resource", "core"),
            ("x-ratelimit-limit", "100"),
            ("x-ratelimit-remaining", "100"),
            ("x-ratelimit-reset", reset.as_str()),
        ]))
        .await;
    let guard = budget.acquire(RateLimitResource::Core, 5).await;
    assert!(guard.is_ok());
}

#[tokio::test]
async fn expired_cooling_state_is_cleared_on_next_check() {
    let budget = GithubRateBudget::new(4, 50);
    budget
        .observe_secondary_limit(RateLimitResource::Core, Some(Duration::from_millis(50)))
        .await;
    tokio::time::sleep(Duration::from_millis(80)).await;
    assert!(
        budget
            .current_cooling(RateLimitResource::Core)
            .await
            .is_none()
    );
    let guard = budget.acquire(RateLimitResource::Core, 1).await;
    assert!(guard.is_ok());
}

#[tokio::test]
async fn concurrent_acquire_respects_semaphore_cap() {
    let cap = 3;
    let budget = std::sync::Arc::new(GithubRateBudget::new(cap, 0));
    let barrier = std::sync::Arc::new(Barrier::new(cap));
    let mut handles = Vec::new();
    let in_flight = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let max_seen = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    for _ in 0..cap * 4 {
        let b = std::sync::Arc::clone(&budget);
        let bar = std::sync::Arc::clone(&barrier);
        let inf = std::sync::Arc::clone(&in_flight);
        let max = std::sync::Arc::clone(&max_seen);
        handles.push(tokio::spawn(async move {
            let guard = b
                .acquire(RateLimitResource::Core, 1)
                .await
                .expect("acquire");
            let now = inf.fetch_add(1, std::sync::atomic::Ordering::SeqCst) + 1;
            max.fetch_max(now, std::sync::atomic::Ordering::SeqCst);
            // Hold the permit briefly so contention is real.
            bar.wait().await;
            inf.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
            drop(guard);
        }));
    }
    for h in handles {
        h.await.unwrap();
    }
    let observed = max_seen.load(std::sync::atomic::Ordering::SeqCst);
    assert!(observed <= cap, "observed in-flight {observed} > cap {cap}");
}

#[tokio::test]
async fn defaults_constants_are_reasonable() {
    let budget = GithubRateBudget::new(DEFAULT_CONCURRENCY_CAP, DEFAULT_RESERVE_FLOOR);
    let guard = budget.acquire(RateLimitResource::Core, 1).await;
    assert!(guard.is_ok());
    assert_eq!(DEFAULT_CONCURRENCY_CAP, 8);
    assert_eq!(DEFAULT_RESERVE_FLOOR, 200);
}
