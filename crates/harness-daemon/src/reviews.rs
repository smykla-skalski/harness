// Deliberate public API facade, not scaffolding: mirrors root's own
// `src/reviews/mod.rs` facade over the same `harness_reviews` crate, at the
// same visibility, for the same reason. `harness_reviews` itself declares
// `avatar`, `body_update`, `enums`, `file_comment`, `files`, `github`,
// `policy`, `review_thread_resolve`, `timeline`, and `types` as fully `pub`
// modules, so re-exporting it with a single glob would leak every one of
// those module paths as part of this crate's own public API and drift
// further open every time `harness_reviews` adds a public item. Individual
// wrapper modules below hold that surface to the exact shape `crate::daemon`
// (this crate's only `crate::reviews` consumer, matching root's own) needs:
// `pub(crate)` where a module-qualified path is actually reached, private
// where only specific re-exported items are, and `pub` only on the items
// that shape stays curated.
mod avatar {
    pub use harness_reviews::avatar::*;
}
mod body_update {
    pub use harness_reviews::body_update::*;
}
mod enums {
    pub use harness_reviews::enums::*;
}
mod file_comment {
    pub use harness_reviews::file_comment::*;
}
pub(crate) mod files {
    pub use harness_reviews::files::*;
}
#[cfg(feature = "daemon-runtime")]
mod github {
    pub use harness_reviews::github::*;
}
#[cfg(feature = "daemon-runtime")]
pub(crate) mod policy {
    pub use harness_reviews::policy::*;
}
pub(crate) mod review_thread_resolve {
    pub use harness_reviews::review_thread_resolve::*;
}
pub(crate) mod timeline {
    pub use harness_reviews::timeline::*;
}
mod types {
    pub use harness_reviews::types::*;
}

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
#[cfg(feature = "daemon-runtime")]
pub(crate) use files::local_clone::{
    LocalCloneRegistry, LocalCloneRoot, RegistryEntry, RepoKey,
    local_clone_list_entry_from_registry,
};
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
