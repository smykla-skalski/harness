//! Inline PR file-changes and timeline data layers for the Reviews
//! dashboard, plus the wire types, write actions, GitHub REST/GraphQL
//! client, and PR merge-policy runtime.
//!
//! This is the second of two slices extracting `reviews` from the root
//! crate. The first moved `avatar`, `enums`, `file_comment`, `files`,
//! `review_thread_resolve`, and `timeline` — the pieces with no
//! `task_board` dependency. This slice moves everything else: `github` and
//! `policy` reach into `task_board`'s own already-extracted `github`,
//! `policy`, `policy_graph`, and `policy_runtime` modules, and `logic`,
//! `validation`, `backports`, and `body_update` hold inherent `impl` blocks
//! on `types`'s wire structs, so Rust's orphan rule keeps all four out of
//! any slice that doesn't also bring `types` along.
//!
//! `policy` keeps the `daemon-runtime` gate its old `reviews::policy`
//! declaration carried: real production code for daemon builds, invisible
//! in root's plain default build, matching the feature this crate already
//! defined for `files::patch_rest`.
//!
//! `body_update`, `enums`, `file_comment`, `logic`, `types`, and
//! `validation` are pure-data wire types plus their inherent `impl` blocks,
//! so they now live in `harness-protocol` (see
//! `harness_protocol::daemon::reviews`'s own doc comment) and are
//! re-exported here unchanged so nothing downstream sees a difference.

pub mod avatar;
pub mod backports;
pub use harness_protocol::daemon::reviews::body_update;
pub use harness_protocol::daemon::reviews::enums;
pub use harness_protocol::daemon::reviews::file_comment;
pub mod files;
pub mod github;
pub use harness_protocol::daemon::reviews::logic;
#[cfg(feature = "daemon-runtime")]
pub mod policy;
pub mod review_thread_resolve;
pub mod timeline;
pub use harness_protocol::daemon::reviews::types;
pub use harness_protocol::daemon::reviews::validation;

pub use avatar::{ReviewsAvatarRequest, ReviewsAvatarResponse, fetch_review_avatar};
pub use body_update::{
    ReviewsBodyUpdateOutcome, ReviewsBodyUpdateRequest, ReviewsBodyUpdateResponse,
};
pub use enums::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionPreviewKind, ReviewAuthorAssociation,
    ReviewCheckConclusion, ReviewCheckRunStatus, ReviewCheckStatus, ReviewMergeableState,
    ReviewPullRequestState, ReviewReviewEventState, ReviewReviewStatus,
};
pub use file_comment::{
    ReviewsFileCommentKind, ReviewsFileCommentRequest, ReviewsFileCommentResponse,
};
pub use files::{
    FilesLargeDiffStrategy, HarnessCodeLanguage, LocalCloneListEntry, ReviewFile,
    ReviewFileChangeType, ReviewFilePatch, ReviewFilePreview, ReviewFileServedBy,
    ReviewFileViewedOutcome, ReviewFileViewedState, ReviewFilesViewedResult,
    ReviewFilesViewedTarget, ReviewImageMime, ReviewsFilesBlobRequest, ReviewsFilesBlobResponse,
    ReviewsFilesListRequest, ReviewsFilesListResponse, ReviewsFilesPatchRequest,
    ReviewsFilesPatchResponse, ReviewsFilesPreviewRequest, ReviewsFilesPreviewResponse,
    ReviewsFilesViewedRequest, ReviewsFilesViewedResponse, ReviewsRateLimitSnapshot,
    image_mime_for_path, infer_language,
};
pub use types::{
    PullRequestReview, ReviewActionPreviewTarget, ReviewActionResult, ReviewBackportSource,
    ReviewCheck, ReviewItem, ReviewItemFlags, ReviewRepositoryLabel, ReviewTarget,
    ReviewTargetFlags, ReviewsActionCapabilities, ReviewsActionPreviewRequest,
    ReviewsActionPreviewResponse, ReviewsActionResponse, ReviewsApproveRequest,
    ReviewsApproveRequestSource, ReviewsAutoRequest, ReviewsBodyRequest, ReviewsBodyResponse,
    ReviewsCacheClearResponse, ReviewsCapabilitiesResponse, ReviewsCommentRequest,
    ReviewsLabelRequest, ReviewsMergeRequest, ReviewsPolicyHistoryRequest,
    ReviewsPolicyHistoryResponse, ReviewsPolicyPreviewRequest, ReviewsPolicyPreviewResponse,
    ReviewsPolicyPreviewStep, ReviewsPolicyRunMetrics, ReviewsPolicyRunResponse,
    ReviewsPolicyRunStartRequest, ReviewsPolicyRunStatus, ReviewsPolicyRunStep,
    ReviewsPolicyStatusRequest, ReviewsPolicyStatusResponse, ReviewsPolicyStepType,
    ReviewsPolicySubject, ReviewsPolicyTimelineEntry, ReviewsPolicyTrigger, ReviewsPolicyWait,
    ReviewsPullRequestReference, ReviewsPullRequestResolveRequest,
    ReviewsPullRequestResolveResponse, ReviewsQueryRequest, ReviewsQueryResponse,
    ReviewsRefreshRequest, ReviewsRefreshResponse, ReviewsRepositoryCatalogRequest,
    ReviewsRepositoryCatalogResponse, ReviewsRequestReviewRequest, ReviewsRerunChecksRequest,
    ReviewsSummary,
};

// Re-exports used by `mod tests;` via `use super::*;`. These were previously
// available because the module root pulled them in directly; keep them
// scoped to test builds so the public API stays unchanged.
#[cfg(test)]
use chrono::{DateTime, Utc};
#[cfg(test)]
use harness_task_board::github::GitHubMergeMethod;

#[cfg(test)]
mod tests;
