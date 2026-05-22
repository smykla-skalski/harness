//! GitHub API rate-limit budget tracker for the reviews feature.
//!
//! Reads `X-RateLimit-*` headers + GraphQL `rateLimit{}` fields after each call,
//! gates new acquires behind a `tokio::sync::Semaphore`, and enters a cooling
//! state on `403`/`429` with `Retry-After` or when the remaining budget falls
//! below the reserve floor.
//!
//! This module is the bedrock layer for all HTTP traffic the feature sends to
//! GitHub. Call sites flow:
//!
//! 1. Before the request: `budget.acquire(resource, cost).await?`
//! 2. After the response: `budget.observe_response(headers).await`
//! 3. On `403`/`429`: `budget.observe_secondary_limit(retry_after).await`
//! 4. After a GraphQL response: `budget.observe_graphql_rate_limit(snapshot).await`

#![allow(dead_code)] // wired into call sites in subsequent commits

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use reqwest::header::HeaderMap;
use tokio::sync::{OwnedSemaphorePermit, RwLock, Semaphore};

#[cfg(test)]
mod tests;

/// Default cap on concurrent in-flight GitHub HTTP requests across the feature.
pub(crate) const DEFAULT_CONCURRENCY_CAP: usize = 8;

/// Default reserve floor - acquires that would push `remaining` below this
/// value defer to the next reset window instead of spending the last drops.
pub(crate) const DEFAULT_RESERVE_FLOOR: u32 = 200;

/// Synthetic cooldown applied when the reserve floor blocks an acquire. We
/// don't know exactly when GitHub will reset (the state may be stale) so this
/// is a conservative back-off used when no `reset_at` is available.
pub(crate) const FALLBACK_RESERVE_COOLDOWN: Duration = Duration::from_secs(60);

/// GitHub's discrete rate-limit resources. Each has an independent budget.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum RateLimitResource {
    Core,
    Search,
    Graphql,
    IntegrationManifest,
    SourceImport,
    CodeSearch,
}

impl RateLimitResource {
    fn from_header(value: &str) -> Option<Self> {
        match value {
            "core" => Some(Self::Core),
            "search" => Some(Self::Search),
            "graphql" => Some(Self::Graphql),
            "integration_manifest" => Some(Self::IntegrationManifest),
            "source_import" => Some(Self::SourceImport),
            "code_search" => Some(Self::CodeSearch),
            _ => None,
        }
    }
}

/// Latest known budget for one resource, derived from headers or GraphQL.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RateLimitState {
    pub remaining: u32,
    pub limit: u32,
    pub used: u32,
    pub reset_at: SystemTime,
    pub observed_at: Instant,
}

/// Why the budget is currently cooling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CoolingReason {
    SecondaryRateLimit,
    ReserveFloor,
}

#[derive(Debug, Clone)]
pub(crate) struct CoolingState {
    pub until: Instant,
    pub reason: CoolingReason,
}

/// Returned to callers when the budget refuses an acquire.
#[derive(Debug, Clone)]
pub(crate) struct BudgetError {
    pub resource: RateLimitResource,
    pub until: Instant,
    pub reason: CoolingReason,
}

/// RAII permit held for the lifetime of an outstanding HTTP request.
#[derive(Debug)]
pub(crate) struct AcquireGuard {
    _permit: OwnedSemaphorePermit,
    pub cost: u32,
}

/// Snapshot of GitHub's `rateLimit { remaining limit cost resetAt }` GraphQL
/// node, lifted from a response body by the caller.
#[derive(Debug, Clone, Copy)]
pub(crate) struct GraphqlRateLimit {
    pub remaining: u32,
    pub limit: u32,
    pub cost: u32,
    pub reset_at: SystemTime,
}

pub(crate) struct GithubRateBudget {
    states: Arc<RwLock<HashMap<RateLimitResource, RateLimitState>>>,
    cooling: Arc<RwLock<HashMap<RateLimitResource, CoolingState>>>,
    concurrency: Arc<Semaphore>,
    reserve_floor: u32,
}

impl GithubRateBudget {
    pub(crate) fn new(concurrency_cap: usize, reserve_floor: u32) -> Self {
        let cap = concurrency_cap.max(1);
        Self {
            states: Arc::new(RwLock::new(HashMap::new())),
            cooling: Arc::new(RwLock::new(HashMap::new())),
            concurrency: Arc::new(Semaphore::new(cap)),
            reserve_floor,
        }
    }

    /// Parses `X-RateLimit-*` headers from a GitHub HTTP response and updates
    /// the state for the resource the response targeted.
    pub(crate) async fn observe_response(&self, headers: &HeaderMap) {
        let resource = headers
            .get("x-ratelimit-resource")
            .and_then(|v| v.to_str().ok())
            .and_then(RateLimitResource::from_header)
            .unwrap_or(RateLimitResource::Core);

        let Some(remaining) = parse_u32(headers, "x-ratelimit-remaining") else {
            return;
        };
        let limit = parse_u32(headers, "x-ratelimit-limit").unwrap_or(remaining);
        let used =
            parse_u32(headers, "x-ratelimit-used").unwrap_or(limit.saturating_sub(remaining));
        let reset_at = parse_unix_seconds(headers, "x-ratelimit-reset")
            .unwrap_or_else(|| SystemTime::now() + Duration::from_secs(60));

        let state = RateLimitState {
            remaining,
            limit,
            used,
            reset_at,
            observed_at: Instant::now(),
        };
        self.states.write().await.insert(resource, state);
    }

    /// Records a secondary rate-limit hit (`403`/`429` with `Retry-After`).
    pub(crate) async fn observe_secondary_limit(
        &self,
        resource: RateLimitResource,
        retry_after: Option<Duration>,
    ) {
        let until = Instant::now() + retry_after.unwrap_or(Duration::from_secs(60));
        self.cooling.write().await.insert(
            resource,
            CoolingState {
                until,
                reason: CoolingReason::SecondaryRateLimit,
            },
        );
    }

    /// Records a GraphQL `rateLimit{}` snapshot, lifted from the response body.
    pub(crate) async fn observe_graphql_rate_limit(&self, snapshot: GraphqlRateLimit) {
        let state = RateLimitState {
            remaining: snapshot.remaining,
            limit: snapshot.limit,
            used: snapshot.limit.saturating_sub(snapshot.remaining),
            reset_at: snapshot.reset_at,
            observed_at: Instant::now(),
        };
        self.states
            .write()
            .await
            .insert(RateLimitResource::Graphql, state);
    }

    /// Awaits a permit for one in-flight request against `resource`.
    ///
    /// Returns `BudgetError` immediately (without consuming a permit) if the
    /// resource is in a cooling state or if the predicted cost would push
    /// `remaining` below the reserve floor.
    pub(crate) async fn acquire(
        &self,
        resource: RateLimitResource,
        expected_cost: u32,
    ) -> Result<AcquireGuard, BudgetError> {
        if let Some(err) = self.check_cooling(resource).await {
            return Err(err);
        }
        if let Some(err) = self.check_reserve(resource, expected_cost).await {
            return Err(err);
        }

        let permit = Arc::clone(&self.concurrency)
            .acquire_owned()
            .await
            .expect("rate-limit semaphore is never closed");
        Ok(AcquireGuard {
            _permit: permit,
            cost: expected_cost,
        })
    }

    /// Returns the latest state for a resource, if observed.
    pub(crate) async fn current_state(
        &self,
        resource: RateLimitResource,
    ) -> Option<RateLimitState> {
        self.states.read().await.get(&resource).cloned()
    }

    /// Returns the cooling state for a resource if still active. Expired entries
    /// are evicted as a side effect.
    pub(crate) async fn current_cooling(
        &self,
        resource: RateLimitResource,
    ) -> Option<CoolingState> {
        let now = Instant::now();
        let mut guard = self.cooling.write().await;
        if let Some(state) = guard.get(&resource).cloned() {
            if state.until > now {
                return Some(state);
            }
            guard.remove(&resource);
        }
        None
    }

    async fn check_cooling(&self, resource: RateLimitResource) -> Option<BudgetError> {
        let state = self.current_cooling(resource).await?;
        Some(BudgetError {
            resource,
            until: state.until,
            reason: state.reason,
        })
    }

    async fn check_reserve(
        &self,
        resource: RateLimitResource,
        expected_cost: u32,
    ) -> Option<BudgetError> {
        let state = self.states.read().await.get(&resource).cloned()?;
        let projected = state.remaining.saturating_sub(expected_cost);
        if projected >= self.reserve_floor {
            return None;
        }
        let now = Instant::now();
        let until = system_time_to_instant(state.reset_at, now)
            .unwrap_or_else(|| now + FALLBACK_RESERVE_COOLDOWN);
        let cooling = CoolingState {
            until,
            reason: CoolingReason::ReserveFloor,
        };
        self.cooling.write().await.insert(resource, cooling.clone());
        Some(BudgetError {
            resource,
            until: cooling.until,
            reason: cooling.reason,
        })
    }
}

fn parse_u32(headers: &HeaderMap, name: &str) -> Option<u32> {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse::<u32>().ok())
}

fn parse_unix_seconds(headers: &HeaderMap, name: &str) -> Option<SystemTime> {
    let seconds = headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.trim().parse::<u64>().ok())?;
    Some(UNIX_EPOCH + Duration::from_secs(seconds))
}

fn system_time_to_instant(target: SystemTime, now: Instant) -> Option<Instant> {
    let until_target = target.duration_since(SystemTime::now()).ok()?;
    Some(now + until_target)
}
