use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use chrono::Utc;
use tokio::sync::watch;
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval};

use crate::daemon::db::{AsyncDaemonDb, TaskBoardAutomationRunFence, TaskBoardAutomationRunLease};
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::TaskBoardAutomationRunOutcome;

use super::task_board_db::{TaskBoardSyncCoordinatorFence, TaskBoardSyncCoordinatorFenceDecision};

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, PartialEq, Eq)]
enum LeaseHealth {
    Active,
    Draining,
    Failed(String),
}

pub(crate) struct TaskBoardOrchestratorRunGuard {
    db: AsyncDaemonDb,
    lease: TaskBoardAutomationRunLease,
    shutdown_tx: watch::Sender<bool>,
    health_rx: watch::Receiver<LeaseHealth>,
    heartbeat: Option<JoinHandle<()>>,
}

impl TaskBoardOrchestratorRunGuard {
    pub(crate) fn start(db: &AsyncDaemonDb, lease: TaskBoardAutomationRunLease) -> Self {
        Self::start_with_heartbeat_interval(db, lease, HEARTBEAT_INTERVAL)
    }

    fn start_with_heartbeat_interval(
        db: &AsyncDaemonDb,
        lease: TaskBoardAutomationRunLease,
        heartbeat_interval: Duration,
    ) -> Self {
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let (health_tx, health_rx) = watch::channel(LeaseHealth::Active);
        let heartbeat = tokio::spawn(run_heartbeat(
            db.clone(),
            lease.clone(),
            shutdown_rx,
            health_tx,
            heartbeat_interval,
        ));
        Self {
            db: db.clone(),
            lease,
            shutdown_tx,
            health_rx,
            heartbeat: Some(heartbeat),
        }
    }

    pub(crate) async fn ensure_active(&self) -> Result<(), CliError> {
        match self.check_coordinator_fence().await? {
            TaskBoardSyncCoordinatorFenceDecision::Current => Ok(()),
            TaskBoardSyncCoordinatorFenceDecision::Cancelled(error) => Err(error),
        }
    }

    pub(crate) fn coordinator_fence(&self) -> Arc<dyn TaskBoardSyncCoordinatorFence> {
        Arc::new(TaskBoardRunFenceAdapter {
            db: self.db.clone(),
            lease: self.lease.clone(),
            health_rx: self.health_rx.clone(),
        })
    }

    pub(crate) const fn lease(&self) -> &TaskBoardAutomationRunLease {
        &self.lease
    }

    pub(crate) async fn finalize(
        mut self,
        outcome: TaskBoardAutomationRunOutcome,
        error: Option<&CliError>,
    ) -> Result<TaskBoardAutomationRunOutcome, CliError> {
        let heartbeat_result = self.stop_heartbeat().await;
        let error_kind = error.map(CliError::code);
        let error_message = error.map(ToString::to_string);
        let actual_outcome = self
            .db
            .finalize_task_board_automation_run(
                &self.lease,
                outcome,
                error_kind,
                error_message.as_deref(),
                Utc::now(),
            )
            .await?;
        self.db
            .finish_task_board_automation_drain_if_idle(Utc::now())
            .await?;
        heartbeat_result?;
        Ok(actual_outcome)
    }

    async fn check_coordinator_fence(
        &self,
    ) -> Result<TaskBoardSyncCoordinatorFenceDecision, CliError> {
        check_fence(&self.db, &self.lease, &self.health_rx).await
    }

    async fn stop_heartbeat(&mut self) -> Result<(), CliError> {
        let _ = self.shutdown_tx.send_replace(true);
        let Some(heartbeat) = self.heartbeat.take() else {
            return Ok(());
        };
        heartbeat.await.map_err(|error| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "task-board automation heartbeat task failed: {error}"
            )))
        })
    }
}

impl Drop for TaskBoardOrchestratorRunGuard {
    fn drop(&mut self) {
        if let Some(heartbeat) = self.heartbeat.take() {
            heartbeat.abort();
        }
    }
}

struct TaskBoardRunFenceAdapter {
    db: AsyncDaemonDb,
    lease: TaskBoardAutomationRunLease,
    health_rx: watch::Receiver<LeaseHealth>,
}

#[async_trait]
impl TaskBoardSyncCoordinatorFence for TaskBoardRunFenceAdapter {
    async fn check(&self) -> Result<TaskBoardSyncCoordinatorFenceDecision, CliError> {
        check_fence(&self.db, &self.lease, &self.health_rx).await
    }
}

async fn check_fence(
    db: &AsyncDaemonDb,
    lease: &TaskBoardAutomationRunLease,
    health_rx: &watch::Receiver<LeaseHealth>,
) -> Result<TaskBoardSyncCoordinatorFenceDecision, CliError> {
    if let LeaseHealth::Failed(error) = health_rx.borrow().clone() {
        return Err(heartbeat_error(&error));
    }
    match db
        .heartbeat_task_board_automation_run(lease, Utc::now())
        .await?
    {
        TaskBoardAutomationRunFence::Active => Ok(TaskBoardSyncCoordinatorFenceDecision::Current),
        TaskBoardAutomationRunFence::Draining => Ok(
            TaskBoardSyncCoordinatorFenceDecision::Cancelled(stopping_error()),
        ),
    }
}

async fn run_heartbeat(
    db: AsyncDaemonDb,
    lease: TaskBoardAutomationRunLease,
    mut shutdown_rx: watch::Receiver<bool>,
    health_tx: watch::Sender<LeaseHealth>,
    heartbeat_interval: Duration,
) {
    let mut ticker = interval(heartbeat_interval);
    ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
    ticker.tick().await;
    loop {
        tokio::select! {
            result = shutdown_rx.changed() => {
                if result.is_err() || *shutdown_rx.borrow() {
                    break;
                }
            }
            _ = ticker.tick() => {
                match db.heartbeat_task_board_automation_run(&lease, Utc::now()).await {
                    Ok(TaskBoardAutomationRunFence::Active) => {}
                    Ok(TaskBoardAutomationRunFence::Draining) => {
                        let _ = health_tx.send_replace(LeaseHealth::Draining);
                    }
                    Err(error) => {
                        let _ = health_tx.send_replace(LeaseHealth::Failed(error.to_string()));
                        break;
                    }
                }
            }
        }
    }
}

fn stopping_error() -> CliError {
    CliErrorKind::session_agent_conflict("task-board automation is stopping").into()
}

fn heartbeat_error(error: &str) -> CliError {
    CliErrorKind::workflow_io(format!(
        "task-board automation lease heartbeat failed: {error}"
    ))
    .into()
}

#[cfg(test)]
mod tests {
    use chrono::{DateTime, Duration as ChronoDuration};
    use sqlx::{query, query_as};

    use super::*;
    use crate::daemon::db::{TaskBoardAutomationRunAdmission, TaskBoardRunAcquireRequest};
    use crate::task_board::{
        TaskBoardAutomationDesiredMode, TaskBoardAutomationRunTrigger, TaskBoardAutomationScope,
    };

    async fn database() -> AsyncDaemonDb {
        let temp = tempfile::tempdir().expect("temp dir");
        let path = temp.keep().join("harness.db");
        AsyncDaemonDb::connect(&path).await.expect("open database")
    }

    async fn wait_for_lease_renewal(db: &AsyncDaemonDb, shortened_expiry: DateTime<Utc>) {
        tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let row = query_as::<_, (String,)>(
                    "SELECT lease_expires_at
                     FROM task_board_orchestrator_runs WHERE run_id = ?1",
                )
                .bind("run-long-drain")
                .fetch_one(db.pool())
                .await
                .expect("load lease expiry");
                let expiry = DateTime::parse_from_rfc3339(&row.0)
                    .expect("valid lease expiry")
                    .with_timezone(&Utc);
                if expiry > shortened_expiry {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("draining heartbeat should renew shortened lease");
    }

    #[tokio::test]
    async fn draining_guard_renews_lease_until_finalization() {
        let db = database().await;
        let now = Utc::now();
        db.start_task_board_automation(TaskBoardAutomationDesiredMode::Continuous, now)
            .await
            .expect("start automation");
        let admission = db
            .try_acquire_task_board_automation_run(&TaskBoardRunAcquireRequest {
                run_id: "run-long-drain".into(),
                trigger: TaskBoardAutomationRunTrigger::Scheduled,
                actor: Some("scheduler-test".into()),
                dry_run: false,
                scope: TaskBoardAutomationScope::default(),
                lease_owner: "scheduler-test-owner".into(),
                now,
            })
            .await
            .expect("acquire run");
        let TaskBoardAutomationRunAdmission::Acquired(lease) = admission else {
            panic!("scheduled run should acquire lease");
        };
        let guard = TaskBoardOrchestratorRunGuard::start_with_heartbeat_interval(
            &db,
            lease,
            Duration::from_millis(10),
        );

        db.stop_task_board_automation(Utc::now())
            .await
            .expect("stop automation");
        assert!(matches!(
            guard
                .coordinator_fence()
                .check()
                .await
                .expect("check provider fence"),
            TaskBoardSyncCoordinatorFenceDecision::Cancelled(_)
        ));
        guard
            .ensure_active()
            .await
            .expect_err("draining run must reject a new phase");
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(*guard.health_rx.borrow(), LeaseHealth::Draining);

        let shortened_expiry = Utc::now() + ChronoDuration::seconds(2);
        query(
            "UPDATE task_board_orchestrator_runs
             SET lease_expires_at = ?2 WHERE run_id = ?1",
        )
        .bind("run-long-drain")
        .bind(shortened_expiry.to_rfc3339())
        .execute(db.pool())
        .await
        .expect("shorten lease for accelerated regression");
        wait_for_lease_renewal(&db, shortened_expiry).await;

        assert_eq!(
            guard
                .finalize(TaskBoardAutomationRunOutcome::Completed, None)
                .await
                .expect("finalize long drain"),
            TaskBoardAutomationRunOutcome::Cancelled
        );
        let row = query_as::<_, (String, String)>(
            "SELECT state, outcome FROM task_board_orchestrator_runs WHERE run_id = ?1",
        )
        .bind("run-long-drain")
        .fetch_one(db.pool())
        .await
        .expect("load finalized run");
        assert_eq!(row, ("terminal".into(), "cancelled".into()));
    }
}
