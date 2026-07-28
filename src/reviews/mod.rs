// `avatar`, `enums`, `file_comment`, `files`, `review_thread_resolve`, and
// `timeline` moved into `harness-reviews`: they carry no `task_board`
// dependency. `backports`, `body_update`, `github`, `logic`, `policy`, and
// `types` stay here — they either reach into `task_board` directly, or hold
// inherent impls on wire types `task_board` still owns, and task_board's own
// extraction into a crate isn't finished yet.
mod avatar {
    pub use harness_reviews::avatar::*;
}
mod backports;
mod body_update;
mod enums {
    pub use harness_reviews::enums::*;
}
mod file_comment {
    pub use harness_reviews::file_comment::*;
}
pub(crate) mod files {
    pub use harness_reviews::files::*;
}
mod github;
mod logic;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod policy;
pub(crate) mod review_thread_resolve {
    pub use harness_reviews::review_thread_resolve::*;
}
pub(crate) mod timeline {
    pub use harness_reviews::timeline::*;
}
mod types;
mod validation;

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
#[allow(unused_imports)] // RegistryEntry + RepoKey are used by daemon-service tests.
pub(crate) use files::local_clone::{LocalCloneRegistry, LocalCloneRoot, RegistryEntry, RepoKey};
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use files::preview_from_patch;
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use files::viewed::{ViewedMutation, classify_outcome};
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
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use github::ReviewsGitHubClient;
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
use crate::task_board::github::GitHubMergeMethod;
#[cfg(test)]
use chrono::{DateTime, Utc};

#[cfg(test)]
mod tests;
