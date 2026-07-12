use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch as tokio_watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::service;

const MIN_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(15);
const DEFAULT_HEARTBEAT_INTERVAL: Duration = Duration::from_mins(1);

pub(super) fn spawn_machine_heartbeat_loop(
    db: Arc<AsyncDaemonDb>,
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> JoinHandle<()> {
    spawn_machine_heartbeat_loop_with(db, shutdown_rx, DEFAULT_HEARTBEAT_INTERVAL)
}

fn spawn_machine_heartbeat_loop_with(
    db: Arc<AsyncDaemonDb>,
    shutdown_rx: tokio_watch::Receiver<bool>,
    tick_interval: Duration,
) -> JoinHandle<()> {
    tokio::spawn(run_machine_heartbeat_loop(db, shutdown_rx, tick_interval))
}

async fn run_machine_heartbeat_loop(
    db: Arc<AsyncDaemonDb>,
    mut shutdown_rx: tokio_watch::Receiver<bool>,
    tick_interval: Duration,
) {
    let mut ticker = interval(tick_interval.max(MIN_HEARTBEAT_INTERVAL));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            () = wait_for_shutdown(&mut shutdown_rx) => break,
            _ = ticker.tick() => touch_local(db.as_ref()).await,
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
async fn touch_local(db: &AsyncDaemonDb) {
    match service::touch_task_board_host_local_db(db).await {
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
    use tempfile::tempdir;
    use tokio::sync::watch as tokio_watch;
    use tokio::time::{Duration, sleep, timeout};

    use super::*;
    use crate::task_board::Machine;

    #[tokio::test]
    async fn heartbeat_loop_touches_local_machine_in_database() {
        let temp = tempdir().expect("tempdir");
        let xdg = temp.path().join("xdg");
        let xdg_value = xdg.to_string_lossy().into_owned();
        temp_env::async_with_vars([("XDG_DATA_HOME", Some(xdg_value.as_str()))], async {
            let db = Arc::new(
                AsyncDaemonDb::connect(&temp.path().join("harness.db"))
                    .await
                    .expect("open database"),
            );
            let (tx, rx) = tokio_watch::channel(false);
            let handle =
                spawn_machine_heartbeat_loop_with(Arc::clone(&db), rx, MIN_HEARTBEAT_INTERVAL);

            timeout(Duration::from_secs(2), async {
                loop {
                    if db
                        .task_board_local_machine_id()
                        .await
                        .expect("load local machine id")
                        .is_some()
                    {
                        break;
                    }
                    sleep(Duration::from_millis(10)).await;
                }
            })
            .await
            .expect("heartbeat tick");
            tx.send(true).expect("signal shutdown");
            handle.await.expect("join loop");

            assert_eq!(
                db.task_board_machines().await.expect("load machines").len(),
                1
            );
            assert!(!xdg.join("harness/task-board").exists());
        })
        .await;
    }

    #[tokio::test]
    async fn heartbeat_preserves_local_machine_declarations() {
        let temp = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
            .await
            .expect("open database");
        let mut machine = Machine::new("machine-1", "Local Mac");
        machine.project_types = vec!["swift".to_string()];
        machine.agent_modes = vec![crate::task_board::AgentMode::Interactive];
        db.set_task_board_local_machine(&machine)
            .await
            .expect("seed local machine");

        service::touch_task_board_host_local_db(&db)
            .await
            .expect("touch local machine");

        let stored = db
            .task_board_machines()
            .await
            .expect("load machines")
            .into_iter()
            .next()
            .expect("local machine");
        assert_eq!(stored.project_types, vec!["swift"]);
        assert_eq!(
            stored.agent_modes,
            vec![crate::task_board::AgentMode::Interactive]
        );
    }
}
