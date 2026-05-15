use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch as tokio_watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::service::run_task_board_orchestrator_once_async;
use crate::daemon::service::task_board_orchestrator_status;
use crate::errors::CliError;
use crate::task_board::{TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorStatus};

pub(super) fn spawn_task_board_orchestrator_loop(
    async_db: Arc<AsyncDaemonDb>,
    tick_interval: Duration,
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> JoinHandle<()> {
    tokio::spawn(run_task_board_orchestrator_loop(
        async_db,
        tick_interval,
        shutdown_rx,
    ))
}

async fn run_task_board_orchestrator_loop(
    async_db: Arc<AsyncDaemonDb>,
    tick_interval: Duration,
    mut shutdown_rx: tokio_watch::Receiver<bool>,
) {
    let mut ticker = interval(tick_interval.max(Duration::from_secs(1)));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            () = wait_for_shutdown(&mut shutdown_rx) => break,
            _ = ticker.tick() => run_logged_tick(&async_db).await,
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

async fn run_logged_tick(async_db: &AsyncDaemonDb) {
    let request = TaskBoardOrchestratorRunOnceRequest::default();
    match drive_task_board_orchestrator_once(task_board_orchestrator_status, || {
        run_task_board_orchestrator_once_async(&request, async_db)
    })
    .await
    {
        Ok(true) => tracing::debug!("task-board orchestrator autonomous tick completed"),
        Ok(false) => {}
        Err(error) => tracing::warn!(%error, "task-board orchestrator autonomous tick failed"),
    }
}

async fn drive_task_board_orchestrator_once<StatusFn, RunFn, RunFuture>(
    status: StatusFn,
    run_once: RunFn,
) -> Result<bool, CliError>
where
    StatusFn: FnOnce() -> Result<TaskBoardOrchestratorStatus, CliError>,
    RunFn: FnOnce() -> RunFuture,
    RunFuture: Future<Output = Result<TaskBoardOrchestratorStatus, CliError>>,
{
    let status = status()?;
    if !status.enabled || !status.running {
        return Ok(false);
    }
    run_once().await?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_board::TaskBoardOrchestratorStatus;

    #[tokio::test]
    async fn autonomous_tick_skips_when_not_enabled_or_running() {
        let did_run = drive_task_board_orchestrator_once(
            || Ok(status(false, false)),
            || async { panic!("stopped orchestrator must not run") },
        )
        .await
        .expect("drive tick");

        assert!(!did_run);
    }

    #[tokio::test]
    async fn autonomous_tick_runs_when_start_intent_is_active() {
        let did_run = drive_task_board_orchestrator_once(
            || Ok(status(true, true)),
            || async { Ok(status(true, true)) },
        )
        .await
        .expect("drive tick");

        assert!(did_run);
    }

    fn status(enabled: bool, running: bool) -> TaskBoardOrchestratorStatus {
        TaskBoardOrchestratorStatus {
            enabled,
            running,
            current_tick: None,
            last_run: None,
            workflow_execution_counts: Vec::new(),
            settings: Default::default(),
        }
    }
}
