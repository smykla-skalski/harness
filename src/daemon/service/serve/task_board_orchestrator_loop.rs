use std::future::Future;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch as tokio_watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::errors::CliError;
use crate::feature_flags::task_board_automation_v2_enabled_from_env;
#[cfg(test)]
use crate::task_board::TaskBoardOrchestratorState;
use crate::task_board::{
    TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode,
    TaskBoardAutomationRunTrigger, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorSettings, TaskBoardOrchestratorStatus,
};

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
    let durable_enabled = task_board_automation_v2_enabled_from_env();
    if durable_enabled && let Err(error) = initialize_durable_automation(db.as_ref()).await {
        tracing::error!(%error, "task-board automation startup initialization failed");
        return;
    }
    let mut ticker = interval(tick_interval.max(Duration::from_secs(1)));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            () = wait_for_shutdown(&mut shutdown_rx) => break,
            _ = ticker.tick() => Box::pin(
                run_logged_tick(&state, db.as_ref(), durable_enabled)
            ).await,
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

async fn run_logged_tick(state: &DaemonHttpState, db: &AsyncDaemonDb, durable_enabled: bool) {
    let request = TaskBoardOrchestratorRunOnceRequest::default();
    let result = Box::pin(drive_task_board_orchestrator_once(
        || automation_tick_state(db, durable_enabled),
        || {
            task_board_route_executor::run_once_with_trigger(
                state,
                request,
                TaskBoardAutomationRunTrigger::Scheduled,
            )
        },
    ))
    .await;
    log_tick_result(result);
}

async fn automation_tick_state(
    db: &AsyncDaemonDb,
    durable_enabled: bool,
) -> Result<AutonomousOrchestratorIntent, CliError> {
    if durable_enabled {
        maintain_durable_automation(db, chrono::Utc::now()).await?;
    }
    orchestrator_state(db, durable_enabled).await
}

async fn maintain_durable_automation(
    db: &AsyncDaemonDb,
    now: chrono::DateTime<chrono::Utc>,
) -> Result<(), CliError> {
    db.recover_stale_task_board_automation_runs(now).await?;
    db.finish_task_board_automation_drain_if_idle(now).await?;
    Ok(())
}

async fn orchestrator_state(
    db: &AsyncDaemonDb,
    durable_enabled: bool,
) -> Result<AutonomousOrchestratorIntent, CliError> {
    let state = db.task_board_orchestrator_state().await?;
    let settings = db.task_board_orchestrator_settings().await?;
    if durable_enabled {
        let control = db.task_board_automation_control().await?;
        return Ok(AutonomousOrchestratorIntent {
            enabled: control.desired_mode != TaskBoardAutomationDesiredMode::Off,
            running: control.admission_state == TaskBoardAutomationAdmissionState::Accepting,
            step_mode: control.desired_mode == TaskBoardAutomationDesiredMode::Step,
        });
    }
    Ok(AutonomousOrchestratorIntent {
        enabled: state.enabled,
        running: state.running,
        step_mode: settings.step_mode,
    })
}

async fn initialize_durable_automation(db: &AsyncDaemonDb) -> Result<(), CliError> {
    let state = db.task_board_orchestrator_state().await?;
    let settings = db.task_board_orchestrator_settings().await?;
    let now = chrono::Utc::now();
    db.initialize_task_board_automation_control_from_legacy_intent(
        desired_mode_for_legacy_intent(&state, &settings),
        now,
    )
    .await?;
    maintain_durable_automation(db, now).await?;
    Ok(())
}

const fn desired_mode_for_legacy_intent(
    state: &crate::task_board::TaskBoardOrchestratorState,
    settings: &TaskBoardOrchestratorSettings,
) -> TaskBoardAutomationDesiredMode {
    if !state.enabled || !state.running {
        return TaskBoardAutomationDesiredMode::Off;
    }
    if settings.step_mode {
        TaskBoardAutomationDesiredMode::Step
    } else {
        TaskBoardAutomationDesiredMode::Continuous
    }
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
    use chrono::Duration as ChronoDuration;
    use sqlx::{query, query_as};
    use tempfile::tempdir;

    use super::*;
    use crate::daemon::db::{TaskBoardAutomationRunAdmission, TaskBoardRunAcquireRequest};
    use crate::task_board::TaskBoardAutomationScope;
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

            let loaded = orchestrator_state(&db, false)
                .await
                .expect("load database state");

            assert!(!loaded.enabled);
            assert!(!loaded.running);
        })
        .await;
    }

    #[test]
    fn running_legacy_step_intent_maps_to_step_control() {
        let state = TaskBoardOrchestratorState {
            enabled: true,
            running: true,
            ..TaskBoardOrchestratorState::default()
        };
        let settings = TaskBoardOrchestratorSettings {
            step_mode: true,
            ..TaskBoardOrchestratorSettings::default()
        };

        assert_eq!(
            desired_mode_for_legacy_intent(&state, &settings),
            TaskBoardAutomationDesiredMode::Step
        );
    }

    #[tokio::test]
    async fn startup_bridges_running_legacy_intent_once() {
        let temp = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
            .await
            .expect("open database");
        db.replace_task_board_orchestrator_state(&state(true, true))
            .await
            .expect("save running legacy intent");

        initialize_durable_automation(&db)
            .await
            .expect("initialize automation");

        let control = db
            .task_board_automation_control()
            .await
            .expect("load durable control");
        assert_eq!(
            control.desired_mode,
            TaskBoardAutomationDesiredMode::Continuous
        );
        assert_eq!(
            control.admission_state,
            TaskBoardAutomationAdmissionState::Accepting
        );
    }

    #[tokio::test]
    async fn startup_preserves_an_explicit_durable_stop() {
        let temp = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
            .await
            .expect("open database");
        db.replace_task_board_orchestrator_state(&state(true, true))
            .await
            .expect("save running legacy intent");
        db.start_task_board_automation(
            TaskBoardAutomationDesiredMode::Continuous,
            chrono::Utc::now(),
        )
        .await
        .expect("start durable automation");
        db.stop_task_board_automation(chrono::Utc::now())
            .await
            .expect("stop durable automation");
        db.finish_task_board_automation_drain_if_idle(chrono::Utc::now())
            .await
            .expect("finish durable stop");

        initialize_durable_automation(&db)
            .await
            .expect("reinitialize automation");

        let control = db
            .task_board_automation_control()
            .await
            .expect("load stopped control");
        assert_eq!(control.desired_mode, TaskBoardAutomationDesiredMode::Off);
        assert_eq!(
            control.admission_state,
            TaskBoardAutomationAdmissionState::Stopped
        );
    }

    #[tokio::test]
    async fn durable_tick_recovers_a_dropped_stopping_run_and_finishes_drain() {
        let temp = tempdir().expect("tempdir");
        let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
            .await
            .expect("open database");
        let started_at = chrono::Utc::now();
        db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, started_at)
            .await
            .expect("start automation");
        let admission = db
            .try_acquire_task_board_automation_run(&TaskBoardRunAcquireRequest {
                run_id: "run-dropped-stop".into(),
                trigger: TaskBoardAutomationRunTrigger::Scheduled,
                actor: Some("scheduler-test".into()),
                dry_run: false,
                scope: TaskBoardAutomationScope::default(),
                lease_owner: "scheduler-test-owner".into(),
                now: started_at,
            })
            .await
            .expect("acquire durable run");
        assert!(matches!(
            admission,
            TaskBoardAutomationRunAdmission::Acquired(_)
        ));
        db.stop_task_board_automation(started_at + ChronoDuration::seconds(1))
            .await
            .expect("stop automation");
        let expired_at = started_at - ChronoDuration::seconds(1);
        query(
            "UPDATE task_board_orchestrator_runs
             SET lease_expires_at = ?2 WHERE run_id = ?1",
        )
        .bind("run-dropped-stop")
        .bind(expired_at.to_rfc3339())
        .execute(db.pool())
        .await
        .expect("expire dropped run");

        let state = automation_tick_state(&db, true)
            .await
            .expect("maintain durable tick");

        assert!(!state.enabled);
        assert!(!state.running);
        let run = query_as::<_, (String, String)>(
            "SELECT state, outcome FROM task_board_orchestrator_runs WHERE run_id = ?1",
        )
        .bind("run-dropped-stop")
        .fetch_one(db.pool())
        .await
        .expect("load recovered run");
        assert_eq!(run, ("terminal".into(), "cancelled".into()));
        let control = db
            .task_board_automation_control()
            .await
            .expect("load stopped control");
        assert_eq!(
            control.admission_state,
            TaskBoardAutomationAdmissionState::Stopped
        );
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
            held_dispatches: crate::task_board::TaskBoardHeldDispatchSummary::default(),
            current_tick: None,
            last_run: None,
            workflow_execution_counts: Vec::new(),
            settings: Default::default(),
        }
    }
}
