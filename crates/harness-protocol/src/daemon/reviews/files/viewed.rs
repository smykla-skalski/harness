//! Wire types for the mark-viewed / unmark-viewed mutation. The
//! mutation-vs-skip decision (`ViewedMutation`) and outcome classifier stay
//! in `harness-reviews` (real GraphQL-facing logic); only the
//! request/response DTOs move.

use serde::{Deserialize, Serialize};

use super::ReviewFileViewedState;

/// Request to flip viewed-state on one or more paths within a PR.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsFilesViewedRequest {
    pub pull_request_id: String,
    pub paths: Vec<ReviewFilesViewedTarget>,
}

/// One target within a viewed-state request.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
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
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum ReviewFileViewedOutcome {
    Updated,
    Drifted,
    Failed,
}

/// One result row inside the response.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewFilesViewedResult {
    pub path: String,
    pub outcome: ReviewFileViewedOutcome,
    pub viewer_viewed_state: ReviewFileViewedState,
}

/// Response shape.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
pub struct ReviewsFilesViewedResponse {
    pub pull_request_id: String,
    pub results: Vec<ReviewFilesViewedResult>,
    pub fetched_at: String,
}
