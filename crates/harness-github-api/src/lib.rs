//! GitHub REST/GraphQL client with a shared budget, cache, and usage
//! journal, consumed independently by `task_board`, `reviews`, and `daemon`.
//!
//! This crate cannot depend on the root crate or on `harness-daemon` (daemon
//! is the last thing extracted in this effort), so it does not resolve its
//! own daemon-data-directory root; [`configure_daemon_root`] must be called
//! once by whichever process does own that resolution before any other entry
//! point here runs.

#![deny(unsafe_code)]

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

pub use budget::{GitHubBudgetError, GitHubRateBudget, GitHubRateLimitSnapshot, GitHubRateResource};
pub use cache::GitHubCache;
pub use client::GitHubProtectedClient;
pub use raw::GitHubRestRawResponse;
pub use recorder::GitHubUsageRecorder;
pub use stability::{GitHubReadStabilityError, retry_stable_read};
pub use state::{
    begin_external_mutation, configure_daemon_root, refresh_read_generation,
    republish_current_data_change, stable_data_revision_guard,
};
pub use types::{
    GitHubApiStatus, GitHubCachePolicy, GitHubDataChange, GitHubPriority,
    GitHubPullRequestSnapshot, GitHubRequestDescriptor, GitHubResponseProvenance,
};

#[cfg(any(test, feature = "test-support"))]
pub use state::acquire_global_budget_test_lock;

// These three test modules predate this crate's own `clippy::pedantic` gate
// - they only ever compiled as part of the root crate's `src/`, which never
// ran clippy against its own `#[cfg(test)]` code. Silence the pure style
// lints below rather than rewrite otherwise-passing tests wholesale; fix
// forward in each file as it's touched.
#[cfg(test)]
#[allow(
    clippy::absolute_paths,
    clippy::duration_suboptimal_units,
    clippy::manual_let_else,
    clippy::map_unwrap_or,
    clippy::redundant_closure_for_method_calls,
    clippy::unreadable_literal,
    clippy::unused_async
)]
mod tests;

#[cfg(test)]
#[allow(clippy::absolute_paths, clippy::duration_suboptimal_units, clippy::unused_async)]
mod coherence_tests;

#[cfg(test)]
#[allow(clippy::absolute_paths, clippy::manual_let_else)]
mod mutation_tests;
