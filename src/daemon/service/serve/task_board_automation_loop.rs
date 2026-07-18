use std::future::Future;
use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::Utc;
use sha2::{Digest, Sha256};
use tokio::sync::watch as tokio_watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::{DaemonHttpState, task_board_route_executor};
use crate::daemon::protocol::TaskBoardOrchestratorRunOnceRequest;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    TASK_BOARD_AUTOMATION_WAKE_BATCH_LIMIT, TaskBoardAutomationAdmissionState,
    TaskBoardAutomationDesiredMode, TaskBoardAutomationRetrySettings,
    TaskBoardAutomationRunTrigger, TaskBoardAutomationWakeCause, TaskBoardAutomationWakeEntityKind,
    TaskBoardAutomationWakeEvent, TaskBoardAutomationWakePayload,
    TaskBoardAutomationWakeRecoveryReason, TaskBoardAutomationWakeRequest,
    TaskBoardOrchestratorSettings, TaskBoardOrchestratorState,
};

const MINIMUM_TICK_INTERVAL: Duration = Duration::from_secs(1);
const MAX_COORDINATOR_BACKOFF_SECONDS: u64 = 3_600;

pub(super) fn spawn_task_board_automation_loop(
    state: DaemonHttpState,
    db: Arc<AsyncDaemonDb>,
    tick_interval: Duration,
    shutdown_rx: tokio_watch::Receiver<bool>,
) -> JoinHandle<()> {
    tokio::spawn(run_task_board_automation_loop(
        state,
        db,
        tick_interval,
        shutdown_rx,
    ))
}

async fn run_task_board_automation_loop(
    state: DaemonHttpState,
    db: Arc<AsyncDaemonDb>,
    tick_interval: Duration,
    mut shutdown_rx: tokio_watch::Receiver<bool>,
) {
    let change_sequence = match initialize_automation(db.as_ref()).await {
        Ok(sequence) => sequence,
        Err(error) => {
            tracing::error!(%error, "task-board automation startup recovery failed");
            return;
        }
    };
    let mut loop_state = AutomationLoopState::new(change_sequence);
    let mut ticker = interval(tick_interval.max(MINIMUM_TICK_INTERVAL));
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            () = wait_for_shutdown(&mut shutdown_rx) => break,
            _ = ticker.tick() => {
                if let Err(error) = run_loop_tick(&state, db.as_ref(), &mut loop_state).await {
                    loop_state
                        .record_failure(db.as_ref(), &state.daemon_epoch)
                        .await;
                    tracing::warn!(%error, "task-board automation coordinator tick failed");
                }
            }
        }
    }
}

struct AutomationLoopState {
    change_sequence: i64,
    last_reconciliation: Instant,
    retry_not_before: Option<Instant>,
    consecutive_failures: u32,
}

impl AutomationLoopState {
    fn new(change_sequence: i64) -> Self {
        Self {
            change_sequence,
            last_reconciliation: Instant::now(),
            retry_not_before: None,
            consecutive_failures: 0,
        }
    }

    fn is_backing_off(&self) -> bool {
        self.retry_not_before
            .is_some_and(|deadline| Instant::now() < deadline)
    }

    async fn record_failure(&mut self, db: &AsyncDaemonDb, stable_key: &str) {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        let retry = db.task_board_orchestrator_settings().await.map_or_else(
            |_| TaskBoardAutomationRetrySettings::default(),
            |value| value.retry,
        );
        self.retry_not_before =
            Some(Instant::now() + retry_delay(&retry, stable_key, self.consecutive_failures));
    }

    fn record_success(&mut self) {
        self.retry_not_before = None;
        self.consecutive_failures = 0;
        self.last_reconciliation = Instant::now();
    }
}

fn retry_delay(
    retry: &TaskBoardAutomationRetrySettings,
    stable_key: &str,
    failures: u32,
) -> Duration {
    let cap = retry
        .max_delay_seconds
        .clamp(1, MAX_COORDINATOR_BACKOFF_SECONDS);
    let mut seconds = retry.base_delay_seconds.max(1).min(cap);
    let multiplier = u64::from(retry.multiplier.max(1));
    let steps = failures
        .saturating_sub(1)
        .min(retry.max_attempts.saturating_sub(1));
    for _ in 0..steps {
        if seconds >= cap {
            break;
        }
        seconds = seconds.saturating_mul(multiplier).min(cap);
    }
    Duration::from_secs(
        deterministic_jitter(
            seconds,
            stable_key,
            failures,
            retry.deterministic_jitter_percent,
        )
        .min(cap),
    )
}

fn deterministic_jitter(base: u64, stable_key: &str, attempt: u32, percent: u8) -> u64 {
    let percent = u64::from(percent.min(100));
    if percent == 0 {
        return base;
    }
    let digest = Sha256::digest(format!("{stable_key}:{attempt}").as_bytes());
    let sample = u64::from_be_bytes(
        digest[..8]
            .try_into()
            .expect("sha256 prefix is eight bytes"),
    );
    let offset =
        i128::from(sample % (percent.saturating_mul(2).saturating_add(1))) - i128::from(percent);
    let scaled = i128::from(base).saturating_mul(100_i128.saturating_add(offset)) / 100;
    u64::try_from(scaled.max(1)).unwrap_or(u64::MAX)
}

async fn initialize_automation(db: &AsyncDaemonDb) -> Result<i64, CliError> {
    let now = Utc::now();
    initialize_control_from_legacy_intent(db, now).await?;
    let expired = maintain_automation_state(db, now).await?;
    if automatic_runs_enabled(db).await? {
        let reason = if expired > 0 {
            TaskBoardAutomationWakeRecoveryReason::LeaseExpired
        } else {
            TaskBoardAutomationWakeRecoveryReason::Startup
        };
        db.enqueue_task_board_automation_wake_event(
            &TaskBoardAutomationWakeRequest {
                entity_id: None,
                entity_revision: None,
                payload: TaskBoardAutomationWakePayload::recovery(reason),
            },
            now,
        )
        .await?;
    }
    db.current_change_sequence().await
}

async fn maintain_automation_state(
    db: &AsyncDaemonDb,
    now: chrono::DateTime<Utc>,
) -> Result<u64, CliError> {
    db.finish_task_board_automation_drain_if_idle(now).await?;
    let expired = db.recover_stale_task_board_automation_runs(now).await?;
    db.finish_task_board_automation_drain_if_idle(now).await?;
    Ok(expired)
}

async fn initialize_control_from_legacy_intent(
    db: &AsyncDaemonDb,
    now: chrono::DateTime<Utc>,
) -> Result<(), CliError> {
    let state = db.task_board_orchestrator_state().await?;
    let settings = db.task_board_orchestrator_settings().await?;
    db.initialize_task_board_automation_control_from_legacy_intent(
        desired_mode_for_legacy_intent(&state, &settings),
        now,
    )
    .await?;
    Ok(())
}

const fn desired_mode_for_legacy_intent(
    state: &TaskBoardOrchestratorState,
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

async fn run_loop_tick(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    loop_state: &mut AutomationLoopState,
) -> Result<(), CliError> {
    maintain_automation_tick(db).await?;
    if !capture_automatic_change_wakes(db, &mut loop_state.change_sequence).await?
        || loop_state.is_backing_off()
    {
        return Ok(());
    }
    if !automatic_runs_enabled(db).await? {
        return Ok(());
    }
    let wakes = db
        .pending_task_board_automation_wake_events(TASK_BOARD_AUTOMATION_WAKE_BATCH_LIMIT)
        .await?;
    if !wakes.is_empty() {
        process_wake_batch(db, &wakes, |trigger| async move {
            Box::pin(task_board_route_executor::run_once_with_trigger(
                state,
                TaskBoardOrchestratorRunOnceRequest::default(),
                trigger,
            ))
            .await
            .map(|_| ())
        })
        .await?;
        loop_state.record_success();
        return Ok(());
    }
    run_interval_fallback(state, db, loop_state).await
}

async fn maintain_automation_tick(db: &AsyncDaemonDb) -> Result<(), CliError> {
    let now = Utc::now();
    let expired = maintain_automation_state(db, now).await?;
    if expired > 0 && automatic_runs_enabled(db).await? {
        db.enqueue_task_board_automation_wake_event(
            &TaskBoardAutomationWakeRequest {
                entity_id: None,
                entity_revision: None,
                payload: TaskBoardAutomationWakePayload::recovery(
                    TaskBoardAutomationWakeRecoveryReason::LeaseExpired,
                ),
            },
            now,
        )
        .await?;
    }
    Ok(())
}

async fn run_interval_fallback(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    loop_state: &mut AutomationLoopState,
) -> Result<(), CliError> {
    let settings = db.task_board_orchestrator_settings().await?;
    let reconcile_after =
        Duration::from_secs(settings.scheduling.reconcile_interval_seconds.max(1));
    if loop_state.last_reconciliation.elapsed() < reconcile_after {
        return Ok(());
    }
    Box::pin(task_board_route_executor::run_once_with_trigger(
        state,
        TaskBoardOrchestratorRunOnceRequest::default(),
        TaskBoardAutomationRunTrigger::Scheduled,
    ))
    .await?;
    loop_state.record_success();
    Ok(())
}

async fn capture_automatic_change_wakes(
    db: &AsyncDaemonDb,
    change_sequence: &mut i64,
) -> Result<bool, CliError> {
    if !automatic_runs_enabled(db).await? {
        *change_sequence = db.current_change_sequence().await?;
        return Ok(false);
    }
    enqueue_change_wakes(db, change_sequence).await?;
    Ok(true)
}

async fn enqueue_change_wakes(
    db: &AsyncDaemonDb,
    change_sequence: &mut i64,
) -> Result<(), CliError> {
    for (scope, sequence) in db.load_change_tracking_since(*change_sequence).await? {
        if let Some(entity_kind) = wake_entity_kind(&scope) {
            let revision = u64::try_from(sequence).map_err(|error| {
                CliErrorKind::workflow_io(format!(
                    "task-board change sequence is out of range: {error}"
                ))
            })?;
            db.enqueue_task_board_automation_wake_event(
                &TaskBoardAutomationWakeRequest {
                    entity_id: Some(scope),
                    entity_revision: Some(revision),
                    payload: TaskBoardAutomationWakePayload::ledger_changed(entity_kind),
                },
                Utc::now(),
            )
            .await?;
        }
        *change_sequence = (*change_sequence).max(sequence);
    }
    Ok(())
}

fn wake_entity_kind(scope: &str) -> Option<TaskBoardAutomationWakeEntityKind> {
    match scope {
        "task_board:items" => Some(TaskBoardAutomationWakeEntityKind::Item),
        "task_board:runtime_config" => Some(TaskBoardAutomationWakeEntityKind::Settings),
        "task_board:policy_pipeline" => Some(TaskBoardAutomationWakeEntityKind::Policy),
        _ => None,
    }
}

async fn process_wake_batch<Run, RunFuture>(
    db: &AsyncDaemonDb,
    wakes: &[TaskBoardAutomationWakeEvent],
    run: Run,
) -> Result<(), CliError>
where
    Run: FnOnce(TaskBoardAutomationRunTrigger) -> RunFuture,
    RunFuture: Future<Output = Result<(), CliError>>,
{
    // The durable route returns `Ok` only after finalization. A partial run is
    // terminal and acknowledged here; provider-scope backoff owns its retry.
    run(trigger_for_wakes(wakes)).await?;
    let sequences = wakes.iter().map(|wake| wake.sequence).collect::<Vec<_>>();
    db.acknowledge_task_board_automation_wake_events(&sequences, Utc::now())
        .await?;
    Ok(())
}

async fn automatic_runs_enabled(db: &AsyncDaemonDb) -> Result<bool, CliError> {
    let control = db.task_board_automation_control().await?;
    Ok(
        control.desired_mode == TaskBoardAutomationDesiredMode::Continuous
            && control.admission_state == TaskBoardAutomationAdmissionState::Accepting,
    )
}

fn trigger_for_wakes(wakes: &[TaskBoardAutomationWakeEvent]) -> TaskBoardAutomationRunTrigger {
    if wakes
        .iter()
        .any(|wake| wake.payload.cause() == TaskBoardAutomationWakeCause::Recovery)
    {
        return TaskBoardAutomationRunTrigger::Recovery;
    }
    TaskBoardAutomationRunTrigger::Event
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

#[cfg(test)]
#[path = "task_board_automation_loop_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "task_board_automation_loop_recovery_tests.rs"]
mod recovery_tests;
