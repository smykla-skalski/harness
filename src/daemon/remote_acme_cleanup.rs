use std::future::Future;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;

use tokio::runtime::{Handle, Runtime};
use tokio::sync::{Notify, oneshot};

use super::remote_redaction::redact_secret_detail;

#[derive(Clone, Default)]
pub(crate) struct RemoteAcmeCleanupTracker {
    state: Arc<RemoteAcmeCleanupState>,
}

#[derive(Default)]
struct RemoteAcmeCleanupState {
    active: AtomicUsize,
    completed: Notify,
}

impl RemoteAcmeCleanupTracker {
    pub(crate) fn spawn_cleanup<F>(&self, cleanup: F) -> oneshot::Receiver<Result<(), String>>
    where
        F: Future<Output = Result<(), String>> + Send + 'static,
    {
        let (result_tx, result_rx) = oneshot::channel();
        self.state.active.fetch_add(1, Ordering::AcqRel);
        let activity = RemoteAcmeCleanupActivity {
            state: Arc::clone(&self.state),
        };
        let task = async move {
            let _activity = activity;
            let result = cleanup.await;
            if let Err(unsent) = result_tx.send(result) {
                log_cleanup_result(&unsent);
            }
        };
        if let Ok(handle) = Handle::try_current() {
            drop(handle.spawn(task));
        } else {
            spawn_fallback_runtime(task);
        }
        result_rx
    }

    pub(crate) async fn wait_for_cleanup(&self) {
        loop {
            let completed = self.state.completed.notified();
            if self.state.active.load(Ordering::Acquire) == 0 {
                return;
            }
            completed.await;
        }
    }
}

struct RemoteAcmeCleanupActivity {
    state: Arc<RemoteAcmeCleanupState>,
}

impl Drop for RemoteAcmeCleanupActivity {
    fn drop(&mut self) {
        if self.state.active.fetch_sub(1, Ordering::AcqRel) == 1 {
            self.state.completed.notify_waiters();
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn spawn_fallback_runtime<F>(task: F)
where
    F: Future<Output = ()> + Send + 'static,
{
    if let Err(error) = thread::Builder::new()
        .name("harness-acme-cleanup".to_string())
        .spawn(move || run_on_fallback_runtime(task))
    {
        tracing::error!(%error, "spawn remote ACME cleanup runtime");
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn run_on_fallback_runtime<F>(task: F)
where
    F: Future<Output = ()>,
{
    match Runtime::new() {
        Ok(runtime) => runtime.block_on(task),
        Err(error) => tracing::error!(%error, "create remote ACME cleanup runtime"),
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_cleanup_result(result: &Result<(), String>) {
    if let Err(error) = result {
        tracing::warn!(
            error = %redact_secret_detail(error),
            "remote ACME challenge cleanup after cancellation failed",
        );
    }
}
