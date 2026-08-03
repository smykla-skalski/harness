//! Service handlers for the inline-PR Files section.
//!
//! Five endpoints back the Monitor's `Reviews > Files` flow:
//!
//! - `list_review_files`        - GraphQL metadata fetch.
//! - `patch_review_files`       - GitHub REST patches.
//! - `mark_review_files_viewed` - hash-guarded mark-viewed batch.
//! - `fetch_review_file_blob`   - image-preview blob fetch.
//! - `preview_review_files`     - bounded patch previews.
//!
//! Patch fetching always uses GitHub REST. The local-clone path and its
//! associated registry, runtime, progress events, and GC were retired.
//! Blob fetching uses GraphQL for text/SVG payloads and falls back to
//! the GitHub git-blob REST endpoint for binary image bytes.

mod blob;
mod list;
mod patch;
mod preview;
#[cfg(test)]
mod tests;
mod token;
mod viewed;

pub use blob::fetch_review_file_blob;
pub use list::list_review_files;
pub use patch::patch_review_files;
pub use preview::preview_review_files;
pub use viewed::mark_review_files_viewed;
