// Deliberate public API facade, not scaffolding: `backports`, `body_update`,
// `github`, `logic`, `policy`, `types`, and `validation` moved into
// `harness_reviews` in this slice, completing the extraction the earlier
// `avatar`/`enums`/`file_comment`/`files`/`review_thread_resolve`/`timeline`
// slice started. `body_update` and `types` get wrapper modules below because
// this file still needs to reach them by name (`pub use body_update::{...}`,
// and so on); `github` and `policy` lost their last root-side call site once
// `harness-daemon` stopped mirroring this crate's own facade and gained its
// own, so neither needs a wrapper here any more. `backports`, `logic`, and
// `validation` have no such call site here (their exported items are
// inherent impls on `types`'s structs, reachable through those structs
// without a module-qualified path) and so need no wrapper.
// Each wrapper restores its outside callers exactly the way root's own
// `task_board/mod.rs` restores task_board's extracted domains through its
// own `pub use harness_task_board::*;`.
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
