use crate::daemon::db::TaskBoardAdmissionWorkerRecovery;
use crate::daemon::db::prelude::*;
use crate::daemon::protocol::ManagedAgentSnapshot;
use crate::daemon::task_board_managed_agents::{
    join_worker_to_workspace, recover_same_applied_worker,
};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::handle::CodexControllerHandle;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;

const MISSING_RUN_RECOVERY_REASON: &str = "Managed worker was missing after daemon restart";

impl CodexControllerHandle {
    pub(crate) async fn reconcile_task_board_admission_workers_after_restart(
        &self,
    ) -> Result<(), CliError> {
        let db = self.state.async_db.get().cloned().ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(
                "task board admission recovery requires the async daemon database".to_string(),
            ))
        })?;
        db.migrate_legacy_task_board_admission_worker_owners()
            .await?;
        for recovery in db.task_board_admission_worker_recoveries().await? {
            Box::pin(self.reconcile_one_admission_worker(db.as_ref(), &recovery)).await?;
        }
        Ok(())
    }

    async fn reconcile_one_admission_worker(
        &self,
        db: &AsyncDaemonDbHandle,
        recovery: &TaskBoardAdmissionWorkerRecovery,
    ) -> Result<(), CliError> {
        if !recovery.managed_worker_id.starts_with("codex-") {
            return Ok(());
        }
        if self.state.active_runs.contains(&recovery.managed_worker_id) {
            return Ok(());
        }
        if db.codex_run(&recovery.managed_worker_id).await?.is_some() {
            return self.reconcile_existing_admission_run(db, recovery).await;
        }
        Box::pin(self.reconcile_missing_admission_run(db, recovery)).await
    }

    async fn reconcile_existing_admission_run(
        &self,
        db: &AsyncDaemonDbHandle,
        recovery: &TaskBoardAdmissionWorkerRecovery,
    ) -> Result<(), CliError> {
        let run = db
            .codex_run(&recovery.managed_worker_id)
            .await?
            .ok_or_else(|| missing_recovered_run_error(recovery))?;
        recover_same_applied_worker(
            ManagedAgentSnapshot::Codex(run),
            &recovery.dispatch,
            &recovery.managed_worker_id,
        )?;
        join_worker_to_workspace(db, &recovery.dispatch, &recovery.managed_worker_id).await?;
        let run = db
            .codex_run(&recovery.managed_worker_id)
            .await?
            .ok_or_else(|| missing_recovered_run_error(recovery))?;
        if !run.status.is_active() {
            db.release_task_board_admission_for_managed_worker(&run.run_id)
                .await?;
        }
        self.reconcile_run(run).map(|_| ())
    }

    #[expect(
        clippy::cognitive_complexity,
        reason = "atomically reconciles a missing durable worker and records the exact recovery result; the closing tracing::warn! dominates this otherwise linear branch"
    )]
    async fn reconcile_missing_admission_run(
        &self,
        db: &AsyncDaemonDbHandle,
        recovery: &TaskBoardAdmissionWorkerRecovery,
    ) -> Result<(), CliError> {
        let Some(outcome) = db
            .reconcile_missing_task_board_admission_worker(recovery, MISSING_RUN_RECOVERY_REASON)
            .await?
        else {
            if db.codex_run(&recovery.managed_worker_id).await?.is_some() {
                self.reconcile_existing_admission_run(db, recovery).await?;
            }
            return Ok(());
        };
        tracing::warn!(
            managed_worker_id = %recovery.managed_worker_id,
            item_id = %outcome.item_id,
            concurrency_released = outcome.concurrency_released,
            progress_changed = outcome.progress_changed,
            "reconciled task-board execution without a durable Codex run",
        );
        Ok(())
    }
}

fn missing_recovered_run_error(recovery: &TaskBoardAdmissionWorkerRecovery) -> CliError {
    CliErrorKind::workflow_io(format!(
        "Codex run '{}' disappeared while binding its workspace owner",
        recovery.managed_worker_id
    ))
    .into()
}
