//! Inline PR file-changes data layer for the Reviews dashboard.
//!
//! The daemon fetches per-file metadata (path, additions, deletions, change
//! type, viewed state) from GitHub via GraphQL, then later fetches patches
//! either over REST (small PRs) or a local bare clone (substantial PRs).
//! Image previews + mark-viewed state round out the surface.
//!
//! Public types live here in `mod.rs`. Submodules will be wired in by
//! subsequent commits (A.3 through A.10):
//!
//! - `list` - GraphQL paginated metadata fetch (this commit, A.2)
//! - `patch_rest` - REST patch fetch with `ETag` (A.3)
//! - `viewed` - GraphQL mark-viewed mutations + hash guard (A.4)
//! - `blob` - GraphQL image blob fetch (A.5)
//! - `cache` - per-PR on-disk patch cache + GC (A.6)
//! - `local_clone` - bare partial clone registry (A.7)
//! - `patch_local` - `git diff` parser (A.8)
//! - `service` - strategy selector + handlers (A.9-A.10)

#![allow(dead_code)] // wired into service handlers in subsequent commits

pub mod blob;
pub mod cache;
mod language;
pub mod list;
pub mod local_clone;
pub mod local_clone_diff;
pub mod local_clone_progress_event;
pub mod local_clone_runtime;
pub mod patch_local;
pub mod patch_rest;
pub mod preview;
pub mod service;
pub mod viewed;

#[cfg(test)]
mod tests;

pub use blob::{
    ReviewImageMime, ReviewsFilesBlobRequest, ReviewsFilesBlobResponse, image_mime_for_path,
};
pub use language::{HarnessCodeLanguage, infer_language};
pub use local_clone::LocalCloneListEntry;
pub use preview::{preview_from_patch, preview_line_limit};
pub use service::FilesLargeDiffStrategy;
pub use viewed::{
    ReviewFileViewedOutcome, ReviewFilesViewedResult, ReviewFilesViewedTarget,
    ReviewsFilesViewedRequest, ReviewsFilesViewedResponse,
};

// Everything below used to be defined directly in this file: the files-list
// request/response, per-file metadata, the change-type/viewed-state enums,
// the rate-limit snapshot, and the patch/preview request/response/served-by
// types. All of it is pure wire data (the two GraphQL-enum `parse()` mappers
// are self-contained), so it now lives in `harness-protocol` alongside the
// rest of the relocated reviews types (see
// `harness_protocol::daemon::reviews`'s doc comment) and is re-exported here
// unchanged.
pub use harness_protocol::daemon::reviews::files::{
    ReviewFile, ReviewFileChangeType, ReviewFilePatch, ReviewFilePreview, ReviewFileServedBy,
    ReviewFileViewedState, ReviewsFilesListRequest, ReviewsFilesListResponse,
    ReviewsFilesPatchRequest, ReviewsFilesPatchResponse, ReviewsFilesPreviewRequest,
    ReviewsFilesPreviewResponse, ReviewsRateLimitSnapshot,
};

/// Soft cap on paginated `pullRequest.files` queries. GitHub returns up to 100
/// nodes per page; this cap times 100 is the per-PR file limit we'll surface.
pub(crate) const FILES_PAGE_CAP: u32 = 20;

/// Maximum files we'll list per PR regardless of pagination cap.
pub(crate) const FILES_MAX: u32 = FILES_PAGE_CAP * 100;
