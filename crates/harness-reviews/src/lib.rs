//! Inline PR file-changes and timeline data layers for the Reviews
//! dashboard, plus the wire types and write actions that carry no
//! `task_board` dependency.
//!
//! `types`, `logic`, `validation`, `backports`, `body_update`, `github`, and
//! `policy` stay in the root crate's `src/reviews`: they either reach into
//! `task_board` (not yet fully extracted) or hold inherent impls on wire
//! types that live there, so moving them here would need a circular crate
//! dependency back on the root crate.

pub mod avatar;
pub mod enums;
pub mod file_comment;
pub mod files;
pub mod review_thread_resolve;
pub mod timeline;

pub use avatar::{ReviewsAvatarRequest, ReviewsAvatarResponse, fetch_review_avatar};
pub use enums::{
    ReviewActionKind, ReviewActionOutcome, ReviewActionPreviewKind, ReviewAuthorAssociation,
    ReviewCheckConclusion, ReviewCheckRunStatus, ReviewCheckStatus, ReviewMergeableState,
    ReviewPullRequestState, ReviewReviewEventState, ReviewReviewStatus,
};
pub use file_comment::{
    ReviewsFileCommentKind, ReviewsFileCommentRequest, ReviewsFileCommentResponse,
};
