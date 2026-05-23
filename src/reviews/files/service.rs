//! Strategy selection + fallback wiring for the files-section service.
//!
//! Three knobs feed the selector:
//!
//! 1. The user's Settings choice: `AutoLocalClone` (default) or
//!    `ForceGitHubRest`.
//! 2. The PR's total churn (`additions + deletions`) compared against the
//!    threshold (default 500 lines).
//! 3. Whether a local-clone attempt should fall back to REST on failure.
//!
//! This module is purely about routing decisions. The actual fetch (REST vs
//! local clone) lives in `patch_rest.rs` / `patch_local.rs` + the service
//! handler in A.10.

use serde::{Deserialize, Serialize};

/// User-facing toggle in Settings. Picked from the `SwiftUI` Picker;
/// serialized through to the daemon on each request.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum FilesLargeDiffStrategy {
    /// For PRs above the threshold, use the local bare clone.
    #[default]
    AutoLocalClone,
    /// Always use GitHub REST regardless of size (no local clones).
    ForceGitHubRest,
}

/// Configuration knobs the selector reads. Settings-fed; defaults match the
/// plan.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct StrategyConfig {
    pub strategy: FilesLargeDiffStrategy,
    /// Lines of churn above which we'd route to local clone (when
    /// `strategy == AutoLocalClone`).
    pub local_clone_threshold_lines: u32,
    /// True when the daemon detected `git` is unavailable at startup; the
    /// selector permanently degrades to REST in this case.
    pub local_clone_disabled_by_environment: bool,
}

impl Default for StrategyConfig {
    fn default() -> Self {
        Self {
            strategy: FilesLargeDiffStrategy::AutoLocalClone,
            local_clone_threshold_lines: 500,
            local_clone_disabled_by_environment: false,
        }
    }
}

/// Final routing decision produced by the selector.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FetchStrategy {
    GithubRest,
    LocalClone,
}

/// Reason annotation so the UI / logs can explain the routing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StrategyReason {
    UserForcedRest,
    EnvironmentForcedRest,
    UnderThreshold,
    AboveThreshold,
}

/// One row carrying both the chosen strategy and the reason for the choice.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StrategyDecision {
    pub strategy: FetchStrategy,
    pub reason: StrategyReason,
}

/// Pick a strategy for a PR with `total_churn = additions + deletions`.
#[must_use]
pub fn pick_strategy(total_churn: u32, config: StrategyConfig) -> StrategyDecision {
    if config.local_clone_disabled_by_environment {
        return StrategyDecision {
            strategy: FetchStrategy::GithubRest,
            reason: StrategyReason::EnvironmentForcedRest,
        };
    }
    match config.strategy {
        FilesLargeDiffStrategy::ForceGitHubRest => StrategyDecision {
            strategy: FetchStrategy::GithubRest,
            reason: StrategyReason::UserForcedRest,
        },
        FilesLargeDiffStrategy::AutoLocalClone => {
            if total_churn > config.local_clone_threshold_lines {
                StrategyDecision {
                    strategy: FetchStrategy::LocalClone,
                    reason: StrategyReason::AboveThreshold,
                }
            } else {
                StrategyDecision {
                    strategy: FetchStrategy::GithubRest,
                    reason: StrategyReason::UnderThreshold,
                }
            }
        }
    }
}

/// Decide whether a local-clone failure should fall back to REST.
///
/// The plan: local-clone path failures (auth, network, disk) → log warning,
/// fall back to REST, set `served_by_fallback: true` so the UI can surface
/// the degraded provenance.
#[must_use]
pub fn fallback_on_local_clone_failure(reason: &LocalCloneFailure) -> bool {
    match reason {
        LocalCloneFailure::CloneIo
        | LocalCloneFailure::FetchIo
        | LocalCloneFailure::DiffIo
        | LocalCloneFailure::AuthDenied
        | LocalCloneFailure::DiskFull
        | LocalCloneFailure::Cancelled
        | LocalCloneFailure::GitMissing => true,
    }
}

/// Local-clone failure modes the selector knows about.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LocalCloneFailure {
    /// `git clone` returned an IO error (network, DNS, etc.).
    CloneIo,
    /// `git fetch` returned an IO error.
    FetchIo,
    /// `git diff` returned an IO error.
    DiffIo,
    /// Auth was denied - PAT lacks the read scope or repo is private.
    AuthDenied,
    /// `ENOSPC` from the filesystem (disk budget exceeded or system full).
    DiskFull,
    /// Daemon cancelled the in-flight operation (UI navigated away).
    Cancelled,
    /// `git` binary is missing from the PATH (the daemon should have
    /// detected this at startup but defensive routing handles late
    /// surprises).
    GitMissing,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_local_clone_above_threshold() {
        let config = StrategyConfig::default();
        let decision = pick_strategy(1_000, config);
        assert_eq!(decision.strategy, FetchStrategy::LocalClone);
        assert_eq!(decision.reason, StrategyReason::AboveThreshold);
    }

    #[test]
    fn picks_rest_below_threshold() {
        let config = StrategyConfig::default();
        let decision = pick_strategy(100, config);
        assert_eq!(decision.strategy, FetchStrategy::GithubRest);
        assert_eq!(decision.reason, StrategyReason::UnderThreshold);
    }

    #[test]
    fn picks_rest_when_user_forces_rest() {
        let config = StrategyConfig {
            strategy: FilesLargeDiffStrategy::ForceGitHubRest,
            ..StrategyConfig::default()
        };
        let decision = pick_strategy(10_000, config);
        assert_eq!(decision.strategy, FetchStrategy::GithubRest);
        assert_eq!(decision.reason, StrategyReason::UserForcedRest);
    }

    #[test]
    fn picks_rest_when_environment_disabled_local_clone() {
        let config = StrategyConfig {
            strategy: FilesLargeDiffStrategy::AutoLocalClone,
            local_clone_disabled_by_environment: true,
            ..StrategyConfig::default()
        };
        let decision = pick_strategy(10_000, config);
        assert_eq!(decision.strategy, FetchStrategy::GithubRest);
        assert_eq!(decision.reason, StrategyReason::EnvironmentForcedRest);
    }

    #[test]
    fn picks_rest_at_exact_threshold_value() {
        // threshold is exclusive: > 500 routes to clone, == 500 stays REST.
        let config = StrategyConfig::default();
        let decision = pick_strategy(500, config);
        assert_eq!(decision.strategy, FetchStrategy::GithubRest);
    }

    #[test]
    fn picks_clone_one_above_threshold() {
        let config = StrategyConfig::default();
        let decision = pick_strategy(501, config);
        assert_eq!(decision.strategy, FetchStrategy::LocalClone);
    }

    #[test]
    fn fallback_returns_true_for_known_failures() {
        assert!(fallback_on_local_clone_failure(&LocalCloneFailure::CloneIo));
        assert!(fallback_on_local_clone_failure(&LocalCloneFailure::FetchIo));
        assert!(fallback_on_local_clone_failure(&LocalCloneFailure::DiffIo));
        assert!(fallback_on_local_clone_failure(
            &LocalCloneFailure::AuthDenied
        ));
        assert!(fallback_on_local_clone_failure(
            &LocalCloneFailure::DiskFull
        ));
        assert!(fallback_on_local_clone_failure(
            &LocalCloneFailure::Cancelled
        ));
        assert!(fallback_on_local_clone_failure(
            &LocalCloneFailure::GitMissing
        ));
    }

    #[test]
    fn strategy_config_default_matches_plan() {
        let config = StrategyConfig::default();
        assert_eq!(config.strategy, FilesLargeDiffStrategy::AutoLocalClone);
        assert_eq!(config.local_clone_threshold_lines, 500);
        assert!(!config.local_clone_disabled_by_environment);
    }

    #[test]
    fn custom_threshold_routes_above_user_setting() {
        let config = StrategyConfig {
            local_clone_threshold_lines: 2_000,
            ..StrategyConfig::default()
        };
        // 1500 churn under custom 2000 threshold → REST.
        let under = pick_strategy(1_500, config);
        assert_eq!(under.strategy, FetchStrategy::GithubRest);
        let over = pick_strategy(2_500, config);
        assert_eq!(over.strategy, FetchStrategy::LocalClone);
    }
}
