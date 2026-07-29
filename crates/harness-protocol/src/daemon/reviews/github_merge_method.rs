//! `GitHubMergeMethod` lives here rather than in `harness-task-board`
//! because 5 of the reviews wire types (`ReviewsMergeRequest`,
//! `ReviewsAutoRequest`, `ReviewsActionPreviewRequest`,
//! `ReviewsPolicyPreviewRequest`, `ReviewsPolicyRunStartRequest`) embed it
//! directly as a `method` field. It is pure data with no inherent methods,
//! so moving it alongside the reviews types it's embedded in avoids giving
//! `harness-protocol` a dependency on `harness-task-board` (which itself
//! depends on `harness-protocol`, so that direction would cycle).
//! `harness-task-board::github_config` re-exports this type unchanged.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum GitHubMergeMethod {
    #[default]
    Squash,
    Merge,
    Rebase,
}
