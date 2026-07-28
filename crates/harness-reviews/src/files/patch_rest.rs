//! REST-path patch fetch for the reviews Files section.
//!
//! GitHub's REST endpoint `GET /repos/{owner}/{repo}/pulls/{n}/files` returns
//! up to 30 files per page with a per-file `patch` string (possibly
//! truncated at ~3000 lines). We page until `Link: rel="next"` is exhausted
//! or `FILES_PAGE_CAP` pages have been visited. `ETag` support: callers pass
//! `If-None-Match: <etag>` per cached file; a 304 response is treated as
//! "still valid".
//!
//! The implementation is split across companion submodules:
//!
//! - [`parsing`]: pure helpers for REST-response parsing, path filtering,
//!   drift checks, and truncation labeling.
//! - [`fetcher`]: the protected REST fetcher and its error type.
//!
//! Tests live in [`tests`].

mod fetcher;
mod parsing;

// Predates this crate's own clippy::pedantic gate (`revision`/`scan`
// submodules included); allow the pure style lints rather than rewrite.
#[cfg(test)]
#[allow(
    clippy::absolute_paths,
    clippy::cognitive_complexity,
    clippy::doc_markdown,
    clippy::format_push_string,
    clippy::items_after_statements
)]
mod tests;

#[cfg(any(test, feature = "daemon-runtime"))]
pub use fetcher::{any_patch_matches, fetch_patches};
pub use parsing::split_repo_full_name;
