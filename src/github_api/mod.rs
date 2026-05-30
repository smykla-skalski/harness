mod budget;
mod cache;
mod client;
mod predictor;
mod raw;
mod recorder;
mod response;
mod state;
mod types;

pub(crate) use budget::{
    GitHubBudgetError, GitHubRateBudget, GitHubRateLimitSnapshot, GitHubRateResource,
};
pub(crate) use cache::GitHubCache;
pub(crate) use client::GitHubProtectedClient;
pub(crate) use recorder::GitHubUsageRecorder;
pub(crate) use types::{
    GitHubApiStatus, GitHubCachePolicy, GitHubPriority, GitHubRequestDescriptor,
    GitHubResponseProvenance,
};

#[cfg(test)]
pub(crate) use state::acquire_global_budget_test_lock;

#[cfg(test)]
mod tests;
