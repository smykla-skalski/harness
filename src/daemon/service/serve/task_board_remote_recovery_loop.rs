use std::time::{Duration, Instant};

use chrono::{DateTime, Utc};
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::{Instant as TokioInstant, sleep_until};

use crate::daemon::db::{AsyncDaemonDb, TaskBoardRemoteRecoveryBatch, utc_now};
use crate::daemon::http::DaemonHttpState;
use crate::errors::{CliError, CliErrorKind};

const MINIMUM_RETRY: Duration = Duration::from_secs(1);
const MAXIMUM_RETRY: Duration = Duration::from_secs(60);
const MAXIMUM_FALLBACK: Duration = Duration::from_secs(30);
const MAXIMUM_STARTUP_PAGES: usize = 64;
const MAXIMUM_FOREGROUND_PAGES: usize = 64;

pub(super) fn spawn_task_board_remote_recovery_loop(
    state: DaemonHttpState,
    fallback_interval: Duration,
    shutdown_rx: watch::Receiver<bool>,
) -> JoinHandle<()> {
    tokio::spawn(run_remote_recovery_loop(
        state,
        fallback_interval.clamp(MINIMUM_RETRY, MAXIMUM_FALLBACK),
        shutdown_rx,
    ))
}

async fn run_remote_recovery_loop(
    state: DaemonHttpState,
    fallback_interval: Duration,
    mut shutdown_rx: watch::Receiver<bool>,
) {
    let Some(db) = state.async_db.get().cloned() else {
        return;
    };
    let mut schedule = RecoverySchedule::new(fallback_interval);
    maintain_remote_recovery_after_controller(&state, db.as_ref(), &mut schedule).await;
    loop {
        tokio::select! {
            changed = shutdown_rx.changed() => {
                if changed.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
            () = sleep_until(TokioInstant::from_std(schedule.next_wake)) => {
                maintain_remote_recovery_after_controller(&state, db.as_ref(), &mut schedule).await;
            }
        }
    }
}

pub(crate) async fn recover_remote_assignments_before_local_work(
    _state: &DaemonHttpState,
    db: &AsyncDaemonDb,
) -> Result<(), CliError> {
    for _ in 0..MAXIMUM_FOREGROUND_PAGES {
        let report = crate::daemon::service::task_board_remote_controller::drive_task_board_remote_controller_before_local_work(
            db,
        )
        .await?;
        if !report.scan_incomplete {
            return recover_remote_assignments_before_work(db).await;
        }
    }
    Err(CliErrorKind::concurrent_modification(
        "remote controller verification remains incomplete before local work",
    )
    .into())
}

pub(crate) async fn recover_remote_assignments_before_work(
    db: &AsyncDaemonDb,
) -> Result<(), CliError> {
    for _ in 0..MAXIMUM_FOREGROUND_PAGES {
        let batch = db.recover_task_board_remote_assignments(&utc_now()).await?;
        log_recovery_failures(&batch);
        if !batch.incomplete {
            return Ok(());
        }
    }
    Err(CliErrorKind::concurrent_modification(
        "remote assignment recovery remains incomplete before local work",
    )
    .into())
}

pub(crate) async fn recover_remote_assignments_at_startup(
    db: &AsyncDaemonDb,
) -> Result<(), CliError> {
    for _ in 0..MAXIMUM_STARTUP_PAGES {
        let now = utc_now();
        let batch = db.recover_task_board_remote_assignments(&now).await?;
        log_recovery_failures(&batch);
        if !batch.incomplete {
            prune_startup_evidence(db, &now).await;
            return Ok(());
        }
    }
    tracing::warn!(
        pages = MAXIMUM_STARTUP_PAGES,
        "remote assignment startup recovery left a fenced backlog for the background loop"
    );
    prune_startup_evidence(db, &utc_now()).await;
    Ok(())
}

pub(crate) async fn recover_remote_assignments_at_startup_with_controller(
    _state: &DaemonHttpState,
    db: &AsyncDaemonDb,
) -> Result<(), CliError> {
    for _ in 0..MAXIMUM_STARTUP_PAGES {
        let report = crate::daemon::service::task_board_remote_controller::drive_task_board_remote_controller_before_local_work(
            db,
        )
        .await?;
        if report.scan_incomplete {
            continue;
        }
        let now = utc_now();
        let batch = db.recover_task_board_remote_assignments(&now).await?;
        log_recovery_failures(&batch);
        if !batch.incomplete {
            prune_startup_evidence(db, &now).await;
            return Ok(());
        }
    }
    tracing::warn!(
        pages = MAXIMUM_STARTUP_PAGES,
        "remote assignment startup recovery left a fenced backlog for the background loop"
    );
    prune_startup_evidence(db, &utc_now()).await;
    Ok(())
}

async fn maintain_remote_recovery_after_controller(
    _state: &DaemonHttpState,
    db: &AsyncDaemonDb,
    schedule: &mut RecoverySchedule,
) {
    let (controller_incomplete, controller_retry) = match crate::daemon::service::task_board_remote_controller::drive_task_board_remote_controller(
            db,
        )
        .await
        {
        Ok(report) => {
            for failure in &report.failures {
                tracing::warn!(error = %failure, "task-board remote controller operation failed");
            }
            (
                report.scan_incomplete,
                report.scan_incomplete || report.scan_blocked,
            )
        }
        Err(error) => {
            tracing::warn!(%error, "task-board remote controller reconciliation failed");
            (true, true)
        }
    };
    maintain_remote_recovery_after_coverage(
        db,
        schedule,
        controller_incomplete,
        controller_retry,
    )
    .await;
}

async fn maintain_remote_recovery_after_coverage(
    db: &AsyncDaemonDb,
    schedule: &mut RecoverySchedule,
    controller_incomplete: bool,
    controller_retry: bool,
) {
    if !controller_incomplete {
        maintain_remote_recovery(db, schedule).await;
    }
    if controller_retry {
        schedule.next_wake = schedule.next_wake.min(Instant::now() + MINIMUM_RETRY);
    }
}

async fn maintain_remote_recovery(db: &AsyncDaemonDb, schedule: &mut RecoverySchedule) {
    let result = async {
        let now = utc_now();
        let batch = db.recover_task_board_remote_assignments(&now).await?;
        log_recovery_failures(&batch);
        let deadline = db.task_board_remote_assignment_recovery_deadline().await?;
        db.prune_task_board_remote_execution_evidence(&now).await?;
        Ok::<_, CliError>((batch, deadline))
    }
    .await;
    match result {
        Ok((batch, deadline)) => schedule.record_batch(&batch, deadline.as_deref()),
        Err(error) => {
            tracing::warn!(%error, "task-board remote assignment recovery failed");
            schedule.record_failure();
        }
    }
}

async fn prune_startup_evidence(db: &AsyncDaemonDb, now: &str) {
    if let Err(error) = db.prune_task_board_remote_execution_evidence(now).await {
        tracing::warn!(%error, "task-board remote evidence startup pruning failed");
    }
}

fn log_recovery_failures(batch: &TaskBoardRemoteRecoveryBatch) {
    for failure in &batch.failures {
        tracing::warn!(
            assignment_id = %failure.assignment_id,
            code = %failure.code,
            error = %failure.message,
            "task-board remote assignment recovery row failed"
        );
    }
}

struct RecoverySchedule {
    next_wake: Instant,
    fallback_interval: Duration,
    consecutive_failures: u32,
}

impl RecoverySchedule {
    fn new(fallback_interval: Duration) -> Self {
        Self {
            next_wake: Instant::now(),
            fallback_interval,
            consecutive_failures: 0,
        }
    }

    fn record_batch(&mut self, batch: &TaskBoardRemoteRecoveryBatch, deadline: Option<&str>) {
        self.consecutive_failures = 0;
        if batch.incomplete {
            self.next_wake = Instant::now() + MINIMUM_RETRY;
        } else {
            self.next_wake =
                next_deadline(deadline, self.fallback_interval).unwrap_or_else(|error| {
                    tracing::warn!(%error, "task-board remote recovery deadline is invalid");
                    Instant::now() + MINIMUM_RETRY
                });
        }
    }

    fn record_failure(&mut self) {
        self.consecutive_failures = self.consecutive_failures.saturating_add(1);
        let shift = self.consecutive_failures.saturating_sub(1).min(6);
        let seconds = 1_u64.checked_shl(shift).unwrap_or(64).min(60);
        self.next_wake = Instant::now() + Duration::from_secs(seconds).min(MAXIMUM_RETRY);
    }
}

fn next_deadline(deadline: Option<&str>, fallback_interval: Duration) -> Result<Instant, CliError> {
    let fallback = Instant::now() + fallback_interval;
    let Some(deadline) = deadline else {
        return Ok(fallback);
    };
    let deadline = DateTime::parse_from_rfc3339(deadline)
        .map_err(|error| {
            CliErrorKind::workflow_io(format!("parse remote recovery deadline: {error}"))
        })?
        .with_timezone(&Utc);
    let delay = (deadline - Utc::now())
        .to_std()
        .unwrap_or(MINIMUM_RETRY)
        .max(MINIMUM_RETRY);
    Ok((Instant::now() + delay).min(fallback))
}

#[cfg(test)]
#[path = "task_board_remote_recovery_loop_tests.rs"]
mod tests;
