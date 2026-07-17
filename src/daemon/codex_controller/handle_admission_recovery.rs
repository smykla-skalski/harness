use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardAdmissionMissingRunRecovery, TaskBoardAdmissionWorkerRecovery,
};
use crate::daemon::protocol::{CodexRunSnapshot, TaskBoardEvaluateRequest};
use crate::daemon::service as daemon_service;
use crate::errors::{CliError, CliErrorKind};

use super::handle::CodexControllerHandle;

const MISSING_RUN_RECOVERY_REASON: &str = "Codex worker was missing after daemon restart";

impl CodexControllerHandle {
    pub(crate) async fn reconcile_task_board_admission_workers_after_restart(
        &self,
    ) -> Result<(), CliError> {
        let db = self.state.async_db.get().cloned().ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(
                "task board admission recovery requires the async daemon database".to_string(),
            ))
        })?;
        for recovery in db.task_board_admission_worker_recoveries().await? {
            if !recovery.managed_worker_id.starts_with("codex-") {
                tracing::warn!(
                    managed_worker_id = %recovery.managed_worker_id,
                    "preserving committed admission for an unsupported managed worker type",
                );
                continue;
            }
            if self.state.active_runs.contains(&recovery.managed_worker_id) {
                continue;
            }
            if let Some(run) = db.codex_run(&recovery.managed_worker_id).await? {
                self.reconcile_existing_admission_run(db.as_ref(), run)
                    .await?;
                continue;
            }
            self.reconcile_missing_admission_run(db.as_ref(), &recovery)
                .await?;
        }
        Ok(())
    }

    async fn reconcile_existing_admission_run(
        &self,
        db: &AsyncDaemonDb,
        run: CodexRunSnapshot,
    ) -> Result<(), CliError> {
        if !run.status.is_active() {
            db.release_task_board_admission_for_managed_worker(&run.run_id)
                .await?;
        }
        self.reconcile_run(run).map(|_| ())
    }

    async fn reconcile_missing_admission_run(
        &self,
        db: &AsyncDaemonDb,
        recovery: &TaskBoardAdmissionWorkerRecovery,
    ) -> Result<(), CliError> {
        let Some(outcome) = db
            .reconcile_missing_task_board_admission_worker(recovery, MISSING_RUN_RECOVERY_REASON)
            .await?
        else {
            if let Some(run) = db.codex_run(&recovery.managed_worker_id).await? {
                self.reconcile_existing_admission_run(db, run).await?;
            }
            return Ok(());
        };
        let publish_result = self.publish_missing_admission_recovery(db, &outcome).await;
        let evaluation_result = daemon_service::evaluate_task_board_async(
            &TaskBoardEvaluateRequest {
                item_id: Some(outcome.item_id.clone()),
                status: None,
                dry_run: false,
            },
            db,
        )
        .await;
        publish_result?;
        evaluation_result?;
        tracing::warn!(
            managed_worker_id = %recovery.managed_worker_id,
            item_id = %outcome.item_id,
            session_id = %outcome.session_id,
            concurrency_released = outcome.concurrency_released,
            session_changed = outcome.session_changed,
            "reconciled committed task board admission without a durable Codex run",
        );
        Ok(())
    }

    async fn publish_missing_admission_recovery(
        &self,
        db: &AsyncDaemonDb,
        outcome: &TaskBoardAdmissionMissingRunRecovery,
    ) -> Result<(), CliError> {
        if !outcome.session_changed {
            return Ok(());
        }
        let mirror_result =
            daemon_service::sync_file_state_from_async_db(db, &outcome.session_id).await;
        let session_change_result = db.bump_change(&outcome.session_id).await;
        let global_change_result = db.bump_change("global").await;
        daemon_service::broadcast_session_snapshot_async(
            &self.state.sender,
            &outcome.session_id,
            Some(db),
        )
        .await;
        mirror_result?;
        session_change_result?;
        global_change_result
    }
}
