mod budget;
mod cache;
mod client;
mod mutation;
mod predictor;
mod raw;
mod recorder;
mod response;
mod stability;
mod state;
mod transport;
mod types;
mod viewer;

pub(crate) use budget::{
    GitHubBudgetError, GitHubRateBudget, GitHubRateLimitSnapshot, GitHubRateResource,
};
pub(crate) use cache::GitHubCache;
pub(crate) use client::GitHubProtectedClient;
pub(crate) use recorder::GitHubUsageRecorder;
pub(crate) use stability::{GitHubReadStabilityError, retry_stable_read};
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use state::stable_data_revision_guard;
pub(crate) use state::{
    begin_external_mutation, refresh_read_generation, republish_current_data_change,
};
pub(crate) use types::{
    GitHubApiStatus, GitHubCachePolicy, GitHubDataChange, GitHubPriority,
    GitHubPullRequestSnapshot, GitHubRequestDescriptor, GitHubResponseProvenance,
};

#[cfg(test)]
pub(crate) use state::acquire_global_budget_test_lock;

#[cfg(test)]
mod tests;

#[cfg(test)]
mod coherence_tests;

#[cfg(test)]
mod mutation_tests;
