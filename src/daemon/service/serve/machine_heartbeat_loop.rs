use std::path::{Path, PathBuf};
use std::time::Duration;

use tokio::sync::watch as tokio_watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};

use crate::task_board::{MachineRegistry, default_board_root};

const MIN_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);
const DEFAULT_HEARTBEAT_INTERVAL: Duration = Duration::from_mins(1);

pub(super) fn spawn_machine_heartbeat_loop(
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> JoinHandle<()> {
    spawn_machine_heartbeat_loop_with(default_board_root, shutdown_rx, DEFAULT_HEARTBEAT_INTERVAL)
}

fn spawn_machine_heartbeat_loop_with<R>(
    board_root: R,
    shutdown_rx: tokio_watch::Receiver<bool>,
    tick_interval: Duration,
) -> JoinHandle<()>
where
    R: Fn() -> PathBuf + Send + 'static,
{
    tokio::spawn(run_machine_heartbeat_loop(
        board_root,
        shutdown_rx,
        tick_interval,
    ))
}

async fn run_machine_heartbeat_loop<R>(
    board_root: R,
    mut shutdown_rx: tokio_watch::Receiver<bool>,
    tick_interval: Duration,
) where
    R: Fn() -> PathBuf + Send,
{
    let mut ticker = interval(tick_interval.max(MIN_HEARTBEAT_INTERVAL));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            () = wait_for_shutdown(&mut shutdown_rx) => break,
            _ = ticker.tick() => touch_local(&board_root()),
        }
    }
}

async fn wait_for_shutdown(shutdown_rx: &mut tokio_watch::Receiver<bool>) {
    if *shutdown_rx.borrow() {
        return;
    }
    while shutdown_rx.changed().await.is_ok() {
        if *shutdown_rx.borrow() {
            break;
        }
    }
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn touch_local(board_root: &Path) {
    let registry = MachineRegistry::new(board_root.to_path_buf());
    match registry.touch_local() {
        Ok(machine) => {
            tracing::debug!(
                machine_id = %machine.id,
                last_seen = %machine.last_seen,
                "machine heartbeat refreshed",
            );
        }
        Err(error) => {
            tracing::warn!(%error, "machine heartbeat failed");
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use tempfile::tempdir;
    use tokio::sync::watch as tokio_watch;
    use tokio::time::{Duration, sleep};

    use super::*;

    #[tokio::test]
    async fn heartbeat_loop_touches_local_on_first_tick() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("board");
        let counter = Arc::new(AtomicUsize::new(0));
        let board_root = root.clone();
        let counter_clone = Arc::clone(&counter);
        let (tx, rx) = tokio_watch::channel(false);

        let handle = spawn_machine_heartbeat_loop_with(
            move || {
                counter_clone.fetch_add(1, Ordering::SeqCst);
                board_root.clone()
            },
            rx,
            MIN_HEARTBEAT_INTERVAL,
        );

        sleep(Duration::from_millis(50)).await;
        tx.send(true).expect("signal shutdown");
        handle.await.expect("join loop");

        assert!(counter.load(Ordering::SeqCst) >= 1);
        assert!(root.join("machines/local.json").exists());
    }
}
