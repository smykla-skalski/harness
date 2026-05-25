use std::time::Duration;

use serde::{Deserialize, Serialize};

use super::budget::GitHubRateResource;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum GitHubPriority {
    Background,
    NormalRead,
    FreshRead,
    Mutation,
}

impl GitHubPriority {
    pub(crate) const fn is_priority(self) -> bool {
        matches!(self, Self::FreshRead | Self::Mutation)
    }

    pub(crate) const fn is_background(self) -> bool {
        matches!(self, Self::Background)
    }

    pub(crate) const fn is_write(self) -> bool {
        matches!(self, Self::Mutation)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct GitHubCachePolicy {
    pub fresh_for: Duration,
    pub stale_for: Duration,
    pub force_refresh: bool,
    pub disk: bool,
}

impl GitHubCachePolicy {
    pub(crate) const fn no_store() -> Self {
        Self {
            fresh_for: Duration::ZERO,
            stale_for: Duration::ZERO,
            force_refresh: true,
            disk: false,
        }
    }

    pub(crate) const fn read_through(fresh_for: Duration, stale_for: Duration) -> Self {
        Self {
            fresh_for,
            stale_for,
            force_refresh: false,
            disk: true,
        }
    }

    pub(crate) const fn is_enabled(self) -> bool {
        self.fresh_for.as_secs() > 0 || self.stale_for.as_secs() > 0
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GitHubRequestDescriptor {
    pub operation: String,
    pub resource: GitHubRateResource,
    pub priority: GitHubPriority,
    pub expected_cost: u32,
    pub cache_policy: GitHubCachePolicy,
}

impl GitHubRequestDescriptor {
    pub(crate) fn graphql(
        operation: impl Into<String>,
        priority: GitHubPriority,
        cache_policy: GitHubCachePolicy,
    ) -> Self {
        Self {
            operation: operation.into(),
            resource: GitHubRateResource::Graphql,
            priority,
            expected_cost: 1,
            cache_policy,
        }
    }

    pub(crate) fn rest_core(
        operation: impl Into<String>,
        priority: GitHubPriority,
        cache_policy: GitHubCachePolicy,
    ) -> Self {
        Self {
            operation: operation.into(),
            resource: GitHubRateResource::Core,
            priority,
            expected_cost: 1,
            cache_policy,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum GitHubResponseCacheState {
    Fresh,
    Stale,
    Revalidated,
    Deferred,
    Miss,
    Disabled,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct GitHubResponseProvenance {
    pub from_cache: bool,
    pub cache_age_seconds: Option<u64>,
    pub cache_state: GitHubResponseCacheState,
    pub rate_limit_snapshot: Option<super::budget::GitHubRateLimitSnapshot>,
}

impl GitHubResponseProvenance {
    pub(crate) const fn network(snapshot: Option<super::budget::GitHubRateLimitSnapshot>) -> Self {
        Self {
            from_cache: false,
            cache_age_seconds: None,
            cache_state: GitHubResponseCacheState::Miss,
            rate_limit_snapshot: snapshot,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct GitHubApiStatus {
    pub buckets: Vec<GitHubRateBucketStatus>,
    pub cooling: Vec<GitHubCooldownStatus>,
    pub last_hour_network_requests: u64,
    pub last_hour_graphql_points: u64,
    pub cache_hits: u64,
    pub cache_stale_hits: u64,
    pub cache_deferred_hits: u64,
    pub deferred_budget: u64,
    pub top_operations: Vec<GitHubOperationSpend>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct GitHubRateBucketStatus {
    pub resource: GitHubRateResource,
    pub remaining: u32,
    pub limit: u32,
    pub used: u32,
    pub reset_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct GitHubCooldownStatus {
    pub resource: GitHubRateResource,
    pub reason: String,
    pub until_seconds_from_now: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct GitHubOperationSpend {
    pub operation: String,
    pub network_requests: u64,
    pub graphql_points: u64,
}
