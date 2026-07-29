use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Duration;

use tokio::task::JoinHandle;

use harness_kernel::errors::CliError;

use crate::task_board::github::{CheckWaitControls, PullRequestEvidenceSource};
use crate::task_board::{
    TaskBoardDependencyCheckResumeOutcome, TaskBoardDependencyCheckResumeSink,
    TaskBoardDependencyCheckWait, observe_task_board_dependency_check_wait,
};

/// Run one exact-head dependency check observer inside the daemon runtime.
///
/// The observer owns no Monitor state. Its source reads GitHub directly and its sink atomically
/// performs the terminal workflow resume, so closing the app cannot stop or duplicate it.
pub fn spawn_dependency_check_wait(
    source: Arc<dyn PullRequestEvidenceSource>,
    wait: TaskBoardDependencyCheckWait,
    max_polls: u32,
    poll_interval: Duration,
    cancel: Arc<AtomicBool>,
    sink: Arc<dyn TaskBoardDependencyCheckResumeSink>,
) -> JoinHandle<Result<TaskBoardDependencyCheckResumeOutcome, CliError>> {
    tokio::spawn(async move {
        observe_task_board_dependency_check_wait(
            source.as_ref(),
            &wait,
            CheckWaitControls {
                max_polls,
                poll_interval,
                cancel: cancel.as_ref(),
            },
            sink.as_ref(),
        )
        .await
    })
}
