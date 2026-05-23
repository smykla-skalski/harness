mod avatar;
mod body_update;
mod enums;
pub(crate) mod files;
mod github;
mod logic;
pub(crate) mod review_thread_resolve;
pub(crate) mod timeline;
mod types;
mod validation;

pub use avatar::{ReviewsAvatarRequest, ReviewsAvatarResponse, fetch_review_avatar};
pub use body_update::{
    ReviewsBodyUpdateOutcome, ReviewsBodyUpdateRequest,
    ReviewsBodyUpdateResponse,
};
pub use enums::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionPreviewKind,
    ReviewCheckConclusion, ReviewCheckRunStatus, ReviewCheckStatus,
    ReviewMergeableState, ReviewPullRequestState, ReviewReviewEventState,
    ReviewReviewStatus,
};
#[allow(unused_imports)] // RegistryEntry + RepoKey are used by daemon-service tests.
pub(crate) use files::local_clone::{LocalCloneRegistry, LocalCloneRoot, RegistryEntry, RepoKey};
pub(crate) use files::preview_from_patch;
pub(crate) use files::viewed::{ViewedMutation, classify_outcome};
pub use files::{
    ReviewFile, ReviewFileChangeType, ReviewFilePatch,
    ReviewFilePreview, ReviewFileServedBy, ReviewFileViewedOutcome,
    ReviewFileViewedState, ReviewFilesViewedResult,
    ReviewFilesViewedTarget, ReviewImageMime,
    ReviewsFilesBlobRequest, ReviewsFilesBlobResponse,
    ReviewsFilesListRequest, ReviewsFilesListResponse,
    ReviewsFilesPatchRequest, ReviewsFilesPatchResponse,
    ReviewsFilesPreviewRequest, ReviewsFilesPreviewResponse,
    ReviewsFilesViewedRequest, ReviewsFilesViewedResponse,
    ReviewsRateLimitSnapshot, FilesLargeDiffStrategy, HarnessCodeLanguage,
    LocalCloneListEntry, image_mime_for_path, infer_language,
};
pub(crate) use github::ReviewsGitHubClient;
pub use types::{
    PullRequestReview, ReviewActionPreviewTarget, ReviewActionResult,
    ReviewCheck, ReviewItem, ReviewItemFlags, ReviewRepositoryLabel,
    ReviewTarget, ReviewTargetFlags,
    ReviewsActionPreviewRequest, ReviewsActionPreviewResponse,
    ReviewsActionResponse, ReviewsApproveRequest, ReviewsAutoRequest,
    ReviewsBodyRequest, ReviewsBodyResponse, ReviewsCacheClearResponse,
    ReviewsActionCapabilities, ReviewsCapabilitiesResponse,
    ReviewsCommentRequest, ReviewsLabelRequest,
    ReviewsMergeRequest, ReviewsQueryRequest, ReviewsQueryResponse,
    ReviewsRefreshRequest, ReviewsRefreshResponse,
    ReviewsRepositoryCatalogRequest, ReviewsRepositoryCatalogResponse,
    ReviewsRequestReviewRequest, ReviewsRerunChecksRequest, ReviewsSummary,
};

// Re-exports used by `mod tests;` via `use super::*;`. These were previously
// available because the module root pulled them in directly; keep them
// scoped to test builds so the public API stays unchanged.
#[cfg(test)]
use chrono::{DateTime, Utc};
#[cfg(test)]
use crate::task_board::github::GitHubMergeMethod;

#[cfg(test)]
mod tests;
