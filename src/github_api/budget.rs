use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Utc};
use reqwest::header::HeaderMap;
use serde::{Deserialize, Serialize};
use tokio::sync::{OwnedSemaphorePermit, RwLock, Semaphore};

use super::predictor::GitHubCostPredictor;
use super::types::{
    GitHubCooldownStatus, GitHubPriority, GitHubRateBucketStatus, GitHubRequestDescriptor,
};

const GLOBAL_NETWORK_CAP: usize = 6;
const BACKGROUND_CAP: usize = 1;
const NORMAL_READ_CAP: usize = 2;
const WRITE_CAP: usize = 2;
const FALLBACK_COOLDOWN: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum GitHubRateResource {
    Core,
    Search,
    Graphql,
    IntegrationManifest,
    SourceImport,
    CodeSearch,
}

impl GitHubRateResource {
    pub(crate) fn from_header(value: &str) -> Option<Self> {
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

    const fn reserve_floor(self, priority: GitHubPriority) -> u32 {
        match (self, priority.is_priority()) {
            (Self::Graphql, true) => 150,
            (Self::Graphql, false) => 750,
            (Self::Core, true) => 100,
            (Self::Core, false) => 500,
            (Self::Search | Self::CodeSearch, true) => 0,
            (Self::Search | Self::CodeSearch, false) => 5,
            (_, _) => 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct GitHubRateLimitSnapshot {
    pub resource: GitHubRateResource,
    pub remaining: u32,
    pub limit: u32,
    pub used: u32,
    pub reset_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost: Option<u32>,
}

#[derive(Debug, Clone)]
struct RateLimitState {
    remaining: u32,
    limit: u32,
    used: u32,
    reset_at: SystemTime,
}

#[derive(Debug, Clone)]
struct CoolingState {
    until: Instant,
    reason: CoolingReason,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CoolingReason {
    SecondaryRateLimit,
    ReserveFloor,
}

impl CoolingReason {
    const fn as_str(self) -> &'static str {
        match self {
            Self::SecondaryRateLimit => "secondary_rate_limit",
            Self::ReserveFloor => "reserve_floor",
        }
    }
}

#[derive(Debug, Clone)]
pub(crate) struct GitHubBudgetError {
    pub resource: GitHubRateResource,
    pub retry_after: Duration,
    pub reason: String,
}

#[derive(Debug)]
pub(crate) struct GitHubBudgetPermit {
    _global: OwnedSemaphorePermit,
    _lane: Option<OwnedSemaphorePermit>,
    reservations: Arc<Mutex<HashMap<GitHubRateResource, u32>>>,
    resource: GitHubRateResource,
    reserved_cost: u32,
}

impl Drop for GitHubBudgetPermit {
    fn drop(&mut self) {
        release_reserved_cost(&self.reservations, self.resource, self.reserved_cost);
    }
}

pub(crate) struct GitHubRateBudget {
    states: RwLock<HashMap<GitHubRateResource, RateLimitState>>,
    cooling: RwLock<HashMap<GitHubRateResource, CoolingState>>,
    reservations: Arc<Mutex<HashMap<GitHubRateResource, u32>>>,
    predictor: RwLock<GitHubCostPredictor>,
    global: Arc<Semaphore>,
    background: Arc<Semaphore>,
    normal_read: Arc<Semaphore>,
    write: Arc<Semaphore>,
}

impl GitHubRateBudget {
    pub(crate) fn new() -> Self {
        Self {
            states: RwLock::new(HashMap::new()),
            cooling: RwLock::new(HashMap::new()),
            reservations: Arc::new(Mutex::new(HashMap::new())),
            predictor: RwLock::new(GitHubCostPredictor::default()),
            global: Arc::new(Semaphore::new(GLOBAL_NETWORK_CAP)),
            background: Arc::new(Semaphore::new(BACKGROUND_CAP)),
            normal_read: Arc::new(Semaphore::new(NORMAL_READ_CAP)),
            write: Arc::new(Semaphore::new(WRITE_CAP)),
        }
    }

    pub(crate) async fn acquire_for(
        &self,
        descriptor: &GitHubRequestDescriptor,
    ) -> Result<GitHubBudgetPermit, GitHubBudgetError> {
        let predicted_cost = self.predicted_cost(descriptor).await;
        self.acquire_reserved(descriptor.resource, descriptor.priority, predicted_cost)
            .await
    }

    pub(crate) async fn observe_operation_cost(
        &self,
        descriptor: &GitHubRequestDescriptor,
        observed_cost: u32,
    ) {
        self.predictor.write().await.observe(
            descriptor.resource,
            &descriptor.operation,
            observed_cost,
        );
    }

    async fn acquire_reserved(
        &self,
        resource: GitHubRateResource,
        priority: GitHubPriority,
        expected_cost: u32,
    ) -> Result<GitHubBudgetPermit, GitHubBudgetError> {
        self.reject_if_cooling(resource).await?;
        let global = Arc::clone(&self.global)
            .acquire_owned()
            .await
            .expect("github global semaphore is never closed");
        let lane = lane_semaphore(self, priority).map(|semaphore| async move {
            semaphore
                .acquire_owned()
                .await
                .expect("github lane semaphore is never closed")
        });
        let lane = match lane {
            Some(future) => Some(future.await),
            None => None,
        };
        self.reserve_if_above_floor(resource, priority, expected_cost)
            .await?;
        Ok(GitHubBudgetPermit {
            _global: global,
            _lane: lane,
            reservations: Arc::clone(&self.reservations),
            resource,
            reserved_cost: expected_cost,
        })
    }

    pub(crate) async fn observe_headers(
        &self,
        headers: &HeaderMap,
    ) -> Option<GitHubRateLimitSnapshot> {
        let resource = headers
            .get("x-ratelimit-resource")
            .and_then(|value| value.to_str().ok())
            .and_then(GitHubRateResource::from_header)
            .unwrap_or(GitHubRateResource::Core);
        let remaining = parse_u32(headers, "x-ratelimit-remaining")?;
        let limit = parse_u32(headers, "x-ratelimit-limit").unwrap_or(remaining);
        let used = parse_u32(headers, "x-ratelimit-used")
            .unwrap_or_else(|| limit.saturating_sub(remaining));
        let reset_at = parse_unix_seconds(headers, "x-ratelimit-reset")
            .unwrap_or_else(|| SystemTime::now() + FALLBACK_COOLDOWN);
        self.states.write().await.insert(
            resource,
            RateLimitState {
                remaining,
                limit,
                used,
                reset_at,
            },
        );
        Some(snapshot(resource, remaining, limit, used, reset_at, None))
    }

    pub(crate) async fn observe_graphql_rate_limit(
        &self,
        remaining: u32,
        limit: u32,
        cost: u32,
        reset_at: SystemTime,
    ) -> GitHubRateLimitSnapshot {
        self.states.write().await.insert(
            GitHubRateResource::Graphql,
            RateLimitState {
                remaining,
                limit,
                used: limit.saturating_sub(remaining),
                reset_at,
            },
        );
        snapshot(
            GitHubRateResource::Graphql,
            remaining,
            limit,
            limit.saturating_sub(remaining),
            reset_at,
            Some(cost),
        )
    }

    pub(crate) async fn observe_secondary_limit(
        &self,
        resource: GitHubRateResource,
        retry_after: Option<Duration>,
    ) {
        self.cooling.write().await.insert(
            resource,
            CoolingState {
                until: Instant::now() + retry_after.unwrap_or(FALLBACK_COOLDOWN),
                reason: CoolingReason::SecondaryRateLimit,
            },
        );
    }

    pub(crate) async fn bucket_statuses(&self) -> Vec<GitHubRateBucketStatus> {
        self.states
            .read()
            .await
            .iter()
            .map(|(resource, state)| GitHubRateBucketStatus {
                resource: *resource,
                remaining: state.remaining,
                limit: state.limit,
                used: state.used,
                reset_at: rfc3339(state.reset_at),
            })
            .collect()
    }

    pub(crate) async fn cooldown_statuses(&self) -> Vec<GitHubCooldownStatus> {
        let now = Instant::now();
        let mut cooling = self.cooling.write().await;
        cooling.retain(|_, state| state.until > now);
        cooling
            .iter()
            .map(|(resource, state)| GitHubCooldownStatus {
                resource: *resource,
                reason: state.reason.as_str().to_string(),
                until_seconds_from_now: state.until.saturating_duration_since(now).as_secs(),
            })
            .collect()
    }

    async fn reject_if_cooling(
        &self,
        resource: GitHubRateResource,
    ) -> Result<(), GitHubBudgetError> {
        let now = Instant::now();
        let mut cooling = self.cooling.write().await;
        let Some(state) = cooling.get(&resource).cloned() else {
            return Ok(());
        };
        if state.until <= now {
            cooling.remove(&resource);
            return Ok(());
        }
        Err(GitHubBudgetError {
            resource,
            retry_after: state.until.saturating_duration_since(now),
            reason: state.reason.as_str().to_string(),
        })
    }

    async fn reject_if_below_floor(
        &self,
        resource: GitHubRateResource,
        priority: GitHubPriority,
        expected_cost: u32,
    ) -> Result<(), GitHubBudgetError> {
        let Some(state) = self.states.read().await.get(&resource).cloned() else {
            return Ok(());
        };
        let floor = resource.reserve_floor(priority);
        if state.remaining.saturating_sub(expected_cost) >= floor {
            return Ok(());
        }
        let until = reset_instant_or_fallback(state.reset_at);
        self.cooling.write().await.insert(
            resource,
            CoolingState {
                until,
                reason: CoolingReason::ReserveFloor,
            },
        );
        Err(GitHubBudgetError {
            resource,
            retry_after: until.saturating_duration_since(Instant::now()),
            reason: CoolingReason::ReserveFloor.as_str().to_string(),
        })
    }

    async fn reserve_if_above_floor(
        &self,
        resource: GitHubRateResource,
        priority: GitHubPriority,
        expected_cost: u32,
    ) -> Result<(), GitHubBudgetError> {
        self.reject_if_below_floor(resource, priority, expected_cost)
            .await?;
        let Some(state) = self.states.read().await.get(&resource).cloned() else {
            reserve_cost(&self.reservations, resource, expected_cost);
            return Ok(());
        };
        let reserved = reserved_cost(&self.reservations, resource);
        let floor = resource.reserve_floor(priority);
        if state
            .remaining
            .saturating_sub(reserved)
            .saturating_sub(expected_cost)
            >= floor
        {
            reserve_cost(&self.reservations, resource, expected_cost);
            return Ok(());
        }
        let until = reset_instant_or_fallback(state.reset_at);
        self.cooling.write().await.insert(
            resource,
            CoolingState {
                until,
                reason: CoolingReason::ReserveFloor,
            },
        );
        Err(GitHubBudgetError {
            resource,
            retry_after: until.saturating_duration_since(Instant::now()),
            reason: CoolingReason::ReserveFloor.as_str().to_string(),
        })
    }

    async fn predicted_cost(&self, descriptor: &GitHubRequestDescriptor) -> u32 {
        self.predictor.read().await.predicted_cost(
            descriptor.resource,
            &descriptor.operation,
            descriptor.expected_cost,
        )
    }

    #[cfg(test)]
    pub(crate) fn reserved_cost_for(&self, resource: GitHubRateResource) -> u32 {
        reserved_cost(&self.reservations, resource)
    }
}

fn lane_semaphore(budget: &GitHubRateBudget, priority: GitHubPriority) -> Option<Arc<Semaphore>> {
    if priority.is_background() {
        return Some(Arc::clone(&budget.background));
    }
    if priority.is_write() {
        return Some(Arc::clone(&budget.write));
    }
    if matches!(priority, GitHubPriority::NormalRead) {
        return Some(Arc::clone(&budget.normal_read));
    }
    None
}

fn reserve_cost(
    reservations: &Arc<Mutex<HashMap<GitHubRateResource, u32>>>,
    resource: GitHubRateResource,
    cost: u32,
) {
    if cost == 0 {
        return;
    }
    let mut guard = reservations
        .lock()
        .expect("github budget reservations lock poisoned");
    let entry = guard.entry(resource).or_default();
    *entry = entry.saturating_add(cost);
}

fn release_reserved_cost(
    reservations: &Arc<Mutex<HashMap<GitHubRateResource, u32>>>,
    resource: GitHubRateResource,
    cost: u32,
) {
    let Ok(mut guard) = reservations.lock() else {
        return;
    };
    let Some(entry) = guard.get_mut(&resource) else {
        return;
    };
    *entry = entry.saturating_sub(cost);
    if *entry == 0 {
        guard.remove(&resource);
    }
}

fn reserved_cost(
    reservations: &Arc<Mutex<HashMap<GitHubRateResource, u32>>>,
    resource: GitHubRateResource,
) -> u32 {
    reservations
        .lock()
        .expect("github budget reservations lock poisoned")
        .get(&resource)
        .copied()
        .unwrap_or(0)
}

pub(crate) fn parse_retry_after(headers: &HeaderMap) -> Option<Duration> {
    headers
        .get(reqwest::header::RETRY_AFTER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<u64>().ok())
        .map(Duration::from_secs)
}

pub(crate) fn parse_graphql_reset_at(value: &str) -> Option<SystemTime> {
    DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|dt| dt.with_timezone(&Utc).into())
}

fn parse_u32(headers: &HeaderMap, name: &str) -> Option<u32> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<u32>().ok())
}

fn parse_unix_seconds(headers: &HeaderMap, name: &str) -> Option<SystemTime> {
    let seconds = headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<u64>().ok())?;
    Some(UNIX_EPOCH + Duration::from_secs(seconds))
}

fn reset_instant_or_fallback(reset_at: SystemTime) -> Instant {
    let now = Instant::now();
    reset_at
        .duration_since(SystemTime::now())
        .map_or(now + FALLBACK_COOLDOWN, |duration| now + duration)
}

fn snapshot(
    resource: GitHubRateResource,
    remaining: u32,
    limit: u32,
    used: u32,
    reset_at: SystemTime,
    cost: Option<u32>,
) -> GitHubRateLimitSnapshot {
    GitHubRateLimitSnapshot {
        resource,
        remaining,
        limit,
        used,
        reset_at: rfc3339(reset_at),
        cost,
    }
}

fn rfc3339(value: SystemTime) -> String {
    DateTime::<Utc>::from(value).to_rfc3339()
}
