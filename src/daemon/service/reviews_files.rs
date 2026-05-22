//! Service handlers for the inline-PR Files section.
//!
//! Six endpoints back the Monitor's `Reviews > Files` flow:
//!
//! - `list_review_files`        - GraphQL metadata fetch.
//! - `patch_review_files`       - REST or local-clone patches.
//! - `mark_review_files_viewed` - hash-guarded mark-viewed batch.
//! - `fetch_review_file_blob`   - image-preview blob fetch.
//! - `list_review_local_clones` - Settings-panel listing.
//! - `delete_review_local_clone` - Settings-panel deletion.
//!
//! The list, patch, viewed, blob, and local-clone endpoints are real
//! implementations. Patch fetching prefers the local-clone path when the
//! caller supplies PR ref context and falls back to GitHub REST. Blob fetching
//! uses GraphQL for text/SVG payloads and falls back to the GitHub git-blob
//! REST endpoint for binary image bytes.

use std::sync::{Arc, OnceLock};

use tokio::sync::broadcast;

use crate::daemon::protocol::StreamEvent;
use crate::reviews::files::local_clone_progress_event::BroadcastProgressSink;
use crate::reviews::files::local_clone_runtime::{
    DiscardProgressSink, LocalCloneProgressSink, LocalCloneRuntime,
};

mod blob;
mod clones;
mod gc;
mod list;
mod patch;
#[cfg(test)]
mod tests;
mod token;
mod viewed;

pub(crate) use blob::BlobTextProjection;
pub use blob::fetch_review_file_blob;
pub use clones::{delete_review_local_clone, list_review_local_clones};
pub use gc::{GcReport, run_local_clone_gc};
pub use list::list_review_files;
pub use patch::patch_review_files;
pub use viewed::mark_review_files_viewed;

const CLONES_SUBDIR: &str = "reviews/clones";

/// Process-wide singletons for the local-clone runtime + progress sender.
///
/// `LOCAL_CLONE_RUNTIME` is constructed on first use; the registry path is
/// derived from `daemon_root() + CLONES_SUBDIR` and only resolved once.
///
/// `PROGRESS_SENDER` is registered explicitly by the daemon HTTP/WS setup
/// so progress events surface on the same broadcast channel the
/// `reviews_local_clone_progress` WS push event flows over.
/// When unset (CLI dry-runs, tests), the handler uses `DiscardProgressSink`
/// and progress events are silently dropped.
static LOCAL_CLONE_RUNTIME: OnceLock<Arc<LocalCloneRuntime>> = OnceLock::new();
static PROGRESS_SENDER: OnceLock<broadcast::Sender<StreamEvent>> = OnceLock::new();

fn local_clone_runtime() -> Arc<LocalCloneRuntime> {
    LOCAL_CLONE_RUNTIME
        .get_or_init(|| Arc::new(LocalCloneRuntime::new(clones::clones_root())))
        .clone()
}

fn progress_sink() -> Arc<dyn LocalCloneProgressSink> {
    if let Some(sender) = PROGRESS_SENDER.get() {
        BroadcastProgressSink::new(sender.clone())
    } else {
        Arc::new(DiscardProgressSink)
    }
}

/// Register the daemon's broadcast sender so the local-clone runtime can
/// fire `reviews_local_clone_progress` push events. Idempotent
/// (first call wins; subsequent calls are no-ops via `OnceLock`).
pub fn register_local_clone_progress_sender(sender: broadcast::Sender<StreamEvent>) {
    let _ = PROGRESS_SENDER.set(sender);
}
