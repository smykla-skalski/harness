use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch as tokio_watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::errors::CliError;
#[cfg(test)]
use crate::task_board::TaskBoardOrchestratorState;
use crate::task_board::{TaskBoardOrchestratorRunOnceRequest, TaskBoardOrchestratorStatus};

struct AutonomousOrchestratorIntent {
    enabled: bool,
    running: bool,
    step_mode: bool,
}

pub(super) fn spawn_task_board_orchestrator_loop(
    state: DaemonHttpState,
    db: Arc<AsyncDaemonDb>,
    tick_interval: Duration,
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> JoinHandle<()> {
    tokio::spawn(run_task_board_orchestrator_loop(
        state,
        db,
        tick_interval,
        shutdown_rx,
    ))
}

async fn run_task_board_orchestrator_loop(
    state: DaemonHttpState,
    db: Arc<AsyncDaemonDb>,
    tick_interval: Duration,
    mut shutdown_rx: tokio_watch::Receiver<bool>,
) {
    let mut ticker = interval(tick_interval.max(Duration::from_secs(1)));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            () = wait_for_shutdown(&mut shutdown_rx) => break,
            _ = ticker.tick() => run_logged_tick(&state, db.as_ref()).await,
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

async fn run_logged_tick(state: &DaemonHttpState, db: &AsyncDaemonDb) {
    let request = TaskBoardOrchestratorRunOnceRequest::default();
    let result = drive_task_board_orchestrator_once(
        || orchestrator_state(db),
        || task_board_route_executor::run_once(state, request),
    )
    .await;
    log_tick_result(result);
}

async fn orchestrator_state(db: &AsyncDaemonDb) -> Result<AutonomousOrchestratorIntent, CliError> {
    let state = db.task_board_orchestrator_state().await?;
    let settings = db.task_board_orchestrator_settings().await?;
    Ok(AutonomousOrchestratorIntent {
        enabled: state.enabled,
        running: state.running,
        step_mode: settings.step_mode,
    })
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

async fn drive_task_board_orchestrator_once<StatusFn, StatusFuture, RunFn, RunFuture>(
    status: StatusFn,
    run_once: RunFn,
) -> Result<bool, CliError>
where
    StatusFn: FnOnce() -> StatusFuture,
    StatusFuture: Future<Output = Result<AutonomousOrchestratorIntent, CliError>>,
    RunFn: FnOnce() -> RunFuture,
    RunFuture: Future<Output = Result<TaskBoardOrchestratorStatus, CliError>>,
{
    let state = status().await?;
    if !state.enabled || !state.running || state.step_mode {
        return Ok(false);
    }
    run_once().await?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;
    use crate::task_board::{TaskBoardOrchestrator, TaskBoardOrchestratorStatus};

    #[tokio::test]
    async fn autonomous_tick_skips_when_not_enabled_or_running() {
        let did_run = drive_task_board_orchestrator_once(
            || async { Ok(intent(false, false, false)) },
            || async { panic!("stopped orchestrator must not run") },
        )
        .await
        .expect("drive tick");

        assert!(!did_run);
    }

    #[tokio::test]
    async fn autonomous_tick_runs_when_start_intent_is_active() {
        let did_run = drive_task_board_orchestrator_once(
            || async { Ok(intent(true, true, false)) },
            || async { Ok(status(true, true)) },
        )
        .await
        .expect("drive tick");

        assert!(did_run);
    }

    #[tokio::test]
    async fn autonomous_tick_skips_in_step_mode() {
        let did_run = drive_task_board_orchestrator_once(
            || async { Ok(intent(true, true, true)) },
            || async { panic!("step mode orchestrator must not run autonomously") },
        )
        .await
        .expect("drive tick");

        assert!(!did_run);
    }

    #[tokio::test]
    async fn autonomous_tick_prefers_database_over_conflicting_legacy_file() {
        let temp = tempdir().expect("tempdir");
        let xdg = temp.path().join("xdg");
        let xdg_value = xdg.to_string_lossy().into_owned();
        temp_env::async_with_vars([("XDG_DATA_HOME", Some(xdg_value.as_str()))], async {
            TaskBoardOrchestrator::new(xdg.join("harness/task-board"))
                .start()
                .expect("start legacy orchestrator");
            let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
                .await
                .expect("open database");
            db.replace_task_board_orchestrator_state(&state(false, false))
                .await
                .expect("save database state");

            let loaded = orchestrator_state(&db).await.expect("load database state");

            assert!(!loaded.enabled);
            assert!(!loaded.running);
        })
        .await;
    }

    fn state(enabled: bool, running: bool) -> TaskBoardOrchestratorState {
        TaskBoardOrchestratorState {
            enabled,
            running,
            ..TaskBoardOrchestratorState::default()
        }
    }

    fn intent(enabled: bool, running: bool, step_mode: bool) -> AutonomousOrchestratorIntent {
        AutonomousOrchestratorIntent {
            enabled,
            running,
            step_mode,
        }
    }

    fn status(enabled: bool, running: bool) -> TaskBoardOrchestratorStatus {
        TaskBoardOrchestratorStatus {
            enabled,
            running,
            step_mode: false,
            current_tick: None,
            last_run: None,
            workflow_execution_counts: Vec::new(),
            settings: Default::default(),
        }
    }
}
