//! Service handlers for task-board working copies (daemon-owned checkouts).
//!
//! Three endpoints back the Monitor's "obtain a working copy" flow for
//! imported items whose repository is not checked out anywhere locally:
//!
//! - `obtain_task_board_working_copy`  - clone-or-reuse a real checkout.
//! - `list_task_board_working_copies`  - Settings/sheet listing.
//! - `delete_task_board_working_copy`  - Settings deletion (reclaims disk).
//!
//! The checkout is a full working tree under
//! `<daemon-root>/task_board/working-copies`, valid as a session `project_dir`
//! once obtained. Progress for the initial clone surfaces on the daemon's WS
//! broadcast channel via the `task_board_working_copy_progress` event.

use std::sync::{Arc, OnceLock};

use tokio::sync::broadcast;

use crate::daemon::protocol::StreamEvent;
use crate::task_board::working_copy::progress::{
    BroadcastProgressSink, DiscardProgressSink, WorkingCopyProgressSink,
};
use crate::task_board::working_copy::runtime::WorkingCopyRuntime;

mod gc;
mod obtain;
mod store;

pub use gc::{WorkingCopyGcReport, run_task_board_working_copy_gc};
pub use obtain::obtain_task_board_working_copy;
pub use store::{delete_task_board_working_copy, list_task_board_working_copies};

const WORKING_COPIES_SUBDIR: &str = "task_board/working-copies";

/// Process-wide singletons for the working-copy runtime + progress sender.
///
/// `WORKING_COPY_RUNTIME` is constructed on first use; the registry path is
/// derived from `daemon_root() + WORKING_COPIES_SUBDIR`.
///
/// `PROGRESS_SENDER` is registered by the daemon HTTP/WS setup so obtain
/// progress surfaces on the same broadcast channel the
/// `task_board_working_copy_progress` WS push event flows over. When unset
/// (CLI dry-runs, tests) the handler uses `DiscardProgressSink`.
static WORKING_COPY_RUNTIME: OnceLock<Arc<WorkingCopyRuntime>> = OnceLock::new();
static PROGRESS_SENDER: OnceLock<broadcast::Sender<StreamEvent>> = OnceLock::new();

fn working_copy_runtime() -> Arc<WorkingCopyRuntime> {
    WORKING_COPY_RUNTIME
        .get_or_init(|| Arc::new(WorkingCopyRuntime::new(store::working_copies_root())))
        .clone()
}

fn progress_sink() -> Arc<dyn WorkingCopyProgressSink> {
    if let Some(sender) = PROGRESS_SENDER.get() {
        BroadcastProgressSink::new(sender.clone())
    } else {
        Arc::new(DiscardProgressSink)
    }
}

/// Register the daemon's broadcast sender so the working-copy runtime can fire
/// `task_board_working_copy_progress` push events. Idempotent (first call wins
/// via `OnceLock`).
pub fn register_task_board_working_copy_progress_sender(sender: broadcast::Sender<StreamEvent>) {
    let _ = PROGRESS_SENDER.set(sender);
}
