use std::future::Future;
use std::time::Duration;

use tokio::sync::watch as tokio_watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};

use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::service::task_board_orchestrator_status;
use crate::errors::CliError;
use crate::task_board::{TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorStatus};

pub(super) fn spawn_task_board_orchestrator_loop(
    state: DaemonHttpState,
    tick_interval: Duration,
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> JoinHandle<()> {
    tokio::spawn(run_task_board_orchestrator_loop(
        state,
        tick_interval,
        shutdown_rx,
    ))
}

async fn run_task_board_orchestrator_loop(
    state: DaemonHttpState,
    tick_interval: Duration,
    mut shutdown_rx: tokio_watch::Receiver<bool>,
) {
    let mut ticker = interval(tick_interval.max(Duration::from_secs(1)));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            () = wait_for_shutdown(&mut shutdown_rx) => break,
            _ = ticker.tick() => run_logged_tick(&state).await,
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

async fn run_logged_tick(state: &DaemonHttpState) {
    let request = TaskBoardOrchestratorRunOnceRequest::default();
    let result = drive_task_board_orchestrator_once(task_board_orchestrator_status, || {
        task_board_route_executor::run_once(state, request)
    })
    .await;
    log_tick_result(result);
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_tick_result(result: Result<bool, CliError>) {
    match result {
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
