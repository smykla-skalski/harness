//! Mark-viewed / unmark-viewed mutations + drift guard.
//!
//! Each toggle is hash-guarded: the caller sends its `expected_prior_viewed_state`,
//! the daemon re-reads the current state via the files list query, compares,
//! and either applies the mutation (state matches) or returns `Drifted` with
//! the current state for the UI to reconcile.
//!
//! Batched toggles are accepted: a single request can carry multiple paths.
//! GitHub's GraphQL doesn't expose a batched mutation for this so the daemon
//! issues per-path mutations sequentially, falling back to the budget tracker
//! between calls.

use serde::{Deserialize, Serialize};

use super::ReviewFileViewedState;

/// Request to flip viewed-state on one or more paths within a PR.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsFilesViewedRequest {
    pub pull_request_id: String,
    pub paths: Vec<ReviewFilesViewedTarget>,
}

/// One target within a viewed-state request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewFilesViewedTarget {
    pub path: String,
    pub expected_prior_state: ReviewFileViewedState,
    pub mark_viewed: bool,
}

impl ReviewsFilesViewedRequest {
    #[must_use]
    pub fn normalized_pull_request_id(&self) -> String {
        self.pull_request_id.trim().to_string()
    }

    #[must_use]
    pub fn normalized_paths(&self) -> Vec<ReviewFilesViewedTarget> {
        self.paths
            .iter()
            .filter_map(|raw| {
                let trimmed = raw.path.trim();
                if trimmed.is_empty() {
                    None
                } else {
                    Some(ReviewFilesViewedTarget {
                        path: trimmed.to_string(),
                        expected_prior_state: raw.expected_prior_state,
                        mark_viewed: raw.mark_viewed,
                    })
                }
            })
            .collect()
    }
}

/// Outcome per path. The Monitor uses this to reconcile its optimistic UI:
/// `Updated` confirms the flip, `Drifted` accepts the daemon's current state,
/// `Failed` rolls back.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewFileViewedOutcome {
    Updated,
    Drifted,
    Failed,
}

/// One result row inside the response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewFilesViewedResult {
    pub path: String,
    pub outcome: ReviewFileViewedOutcome,
    pub viewer_viewed_state: ReviewFileViewedState,
}

/// Response shape.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewsFilesViewedResponse {
    pub pull_request_id: String,
    pub results: Vec<ReviewFilesViewedResult>,
    pub fetched_at: String,
}

/// Decide which GraphQL mutation to issue (mark vs unmark).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ViewedMutation {
    Mark,
    Unmark,
    /// No-op: the desired state already matches the actual state.
    Skip,
}

impl ViewedMutation {
    /// Given the current state on GitHub and the requested action, decide
    /// what to do. If the user wants viewed and the file is already viewed,
    /// we skip (idempotent). Same for unmark.
    #[must_use]
    pub fn decide(current: ReviewFileViewedState, mark_viewed: bool) -> ViewedMutation {
        match (current, mark_viewed) {
            (ReviewFileViewedState::Viewed, true) => Self::Skip,
            (_, true) => Self::Mark,
            (ReviewFileViewedState::Unviewed | ReviewFileViewedState::Dismissed, false) => {
                Self::Skip
            }
            (ReviewFileViewedState::Viewed, false) => Self::Unmark,
        }
    }
}

/// Compute the outcome for one target given the caller's expectation and
/// the daemon's freshly fetched state. Used by the service layer (A.10) to
/// decide whether to apply, drift, or fail.
#[must_use]
pub fn classify_outcome(
    expected_prior: ReviewFileViewedState,
    current_actual: ReviewFileViewedState,
) -> Option<ReviewFileViewedOutcome> {
    if expected_prior == current_actual {
        Some(ReviewFileViewedOutcome::Updated)
    } else {
        Some(ReviewFileViewedOutcome::Drifted)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalized_pull_request_id_trims_whitespace() {
        let request = ReviewsFilesViewedRequest {
            pull_request_id: "  PR_kwDOABC  ".into(),
            paths: vec![],
        };
        assert_eq!(request.normalized_pull_request_id(), "PR_kwDOABC");
    }

    #[test]
    fn normalized_paths_drops_blank_entries() {
        let request = ReviewsFilesViewedRequest {
            pull_request_id: "PR_1".into(),
            paths: vec![
                ReviewFilesViewedTarget {
                    path: "   ".into(),
                    expected_prior_state: ReviewFileViewedState::Unviewed,
                    mark_viewed: true,
                },
                ReviewFilesViewedTarget {
                    path: "src/lib.rs".into(),
                    expected_prior_state: ReviewFileViewedState::Unviewed,
                    mark_viewed: true,
                },
                ReviewFilesViewedTarget {
                    path: "".into(),
                    expected_prior_state: ReviewFileViewedState::Unviewed,
                    mark_viewed: true,
                },
            ],
        };
        let normalized = request.normalized_paths();
        assert_eq!(normalized.len(), 1);
        assert_eq!(normalized[0].path, "src/lib.rs");
    }

    #[test]
    fn viewed_mutation_decides_mark_for_unviewed_target() {
        assert_eq!(
            ViewedMutation::decide(ReviewFileViewedState::Unviewed, true),
            ViewedMutation::Mark
        );
        assert_eq!(
            ViewedMutation::decide(ReviewFileViewedState::Dismissed, true),
            ViewedMutation::Mark
        );
    }

    #[test]
    fn viewed_mutation_decides_unmark_for_viewed_target() {
        assert_eq!(
            ViewedMutation::decide(ReviewFileViewedState::Viewed, false),
            ViewedMutation::Unmark
        );
    }

    #[test]
    fn viewed_mutation_skips_when_state_already_matches() {
        assert_eq!(
            ViewedMutation::decide(ReviewFileViewedState::Viewed, true),
            ViewedMutation::Skip
        );
        assert_eq!(
            ViewedMutation::decide(ReviewFileViewedState::Unviewed, false),
            ViewedMutation::Skip
        );
        assert_eq!(
            ViewedMutation::decide(ReviewFileViewedState::Dismissed, false),
            ViewedMutation::Skip
        );
    }

    #[test]
    fn classify_outcome_returns_updated_on_match() {
        let outcome = classify_outcome(
            ReviewFileViewedState::Unviewed,
            ReviewFileViewedState::Unviewed,
        );
        assert_eq!(outcome, Some(ReviewFileViewedOutcome::Updated));
    }

    #[test]
    fn classify_outcome_returns_drifted_on_mismatch() {
        let outcome = classify_outcome(
            ReviewFileViewedState::Unviewed,
            ReviewFileViewedState::Viewed,
        );
        assert_eq!(outcome, Some(ReviewFileViewedOutcome::Drifted));
    }

    #[test]
    fn response_serializes_round_trip() {
        let response = ReviewsFilesViewedResponse {
            pull_request_id: "PR_1".into(),
            results: vec![ReviewFilesViewedResult {
                path: "src/lib.rs".into(),
                outcome: ReviewFileViewedOutcome::Updated,
                viewer_viewed_state: ReviewFileViewedState::Viewed,
            }],
            fetched_at: "2026-05-22T10:00:00Z".into(),
        };
        let json = serde_json::to_string(&response).expect("serialize");
        let parsed: ReviewsFilesViewedResponse =
            serde_json::from_str(&json).expect("deserialize");
        assert_eq!(parsed, response);
    }
}
