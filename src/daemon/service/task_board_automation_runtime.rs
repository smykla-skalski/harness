use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use serde_json::{Value, json};
use uuid::Uuid;

use crate::daemon::db::{
    AsyncDaemonDb, TaskBoardAutomationRunAdmission, TaskBoardAutomationRunStage,
    TaskBoardRunAcquireRequest,
};
use crate::errors::CliError;
use crate::task_board::{
    TaskBoardAutomationRunOutcome, TaskBoardAutomationRunTrigger, TaskBoardAutomationScope,
};

use super::TaskBoardOrchestratorRunGuard;
use super::task_board_db::TaskBoardSyncRunContext;

pub(crate) enum TaskBoardAutomationRunStart {
    Acquired(Box<TaskBoardAutomationRunSession>),
    Busy { run_id: String },
    Disabled,
}

pub(crate) struct TaskBoardAutomationRunSession {
    db: AsyncDaemonDb,
    guard: Option<TaskBoardOrchestratorRunGuard>,
    run_id: String,
    sync_failed_scopes: Arc<AtomicBool>,
}

impl TaskBoardAutomationRunSession {
    pub(crate) async fn acquire(
        db: &AsyncDaemonDb,
        trigger: TaskBoardAutomationRunTrigger,
        actor: Option<String>,
        dry_run: bool,
        scope: TaskBoardAutomationScope,
    ) -> Result<TaskBoardAutomationRunStart, CliError> {
        let token = Uuid::new_v4().simple().to_string();
        let run_id = format!("task-board-automation-{token}");
        let admission = db
            .try_acquire_task_board_automation_run(&TaskBoardRunAcquireRequest {
                run_id: run_id.clone(),
                trigger,
                actor,
                dry_run,
                scope,
                lease_owner: format!("task-board-coordinator-{token}"),
                now: chrono::Utc::now(),
            })
            .await?;
        let lease = match admission {
            TaskBoardAutomationRunAdmission::Acquired(lease) => lease,
            TaskBoardAutomationRunAdmission::Busy { run_id } => {
                return Ok(TaskBoardAutomationRunStart::Busy { run_id });
            }
            TaskBoardAutomationRunAdmission::Disabled => {
                return Ok(TaskBoardAutomationRunStart::Disabled);
            }
        };
        let session = Self {
            db: db.clone(),
            guard: Some(TaskBoardOrchestratorRunGuard::start(db, lease)),
            run_id,
            sync_failed_scopes: Arc::new(AtomicBool::new(false)),
        };
        Ok(TaskBoardAutomationRunStart::Acquired(Box::new(session)))
    }

    pub(crate) fn run_id(&self) -> &str {
        &self.run_id
    }

    pub(crate) fn sync_context(&self) -> TaskBoardSyncRunContext {
        TaskBoardSyncRunContext::orchestrator(
            Some(self.run_id.clone()),
            Some(self.guard().coordinator_fence()),
            Some(Arc::clone(&self.sync_failed_scopes)),
        )
    }

    pub(crate) fn had_sync_failures(&self) -> bool {
        self.sync_failed_scopes.load(Ordering::SeqCst)
    }

    pub(crate) async fn begin_stage(
        &self,
        sequence: u64,
        stage: &str,
        summary: Option<String>,
        payload: Option<Value>,
    ) -> Result<(), CliError> {
        self.guard().ensure_active().await?;
        self.record_stage(sequence, stage, "running", summary, payload)
            .await
    }

    pub(crate) async fn complete_stage(
        &self,
        sequence: u64,
        stage: &str,
        summary: Option<String>,
        payload: Option<Value>,
    ) -> Result<(), CliError> {
        self.record_stage(sequence, stage, "completed", summary, payload)
            .await
    }

    pub(crate) async fn fail_stage(
        &self,
        sequence: u64,
        stage: &str,
        error: &CliError,
    ) -> Result<(), CliError> {
        self.record_stage(
            sequence,
            stage,
            "failed",
            Some(error.to_string()),
            Some(json!({ "error_kind": error.code() })),
        )
        .await
    }

    pub(crate) async fn finalize(
        mut self,
        outcome: TaskBoardAutomationRunOutcome,
        error: Option<&CliError>,
    ) -> Result<TaskBoardAutomationRunOutcome, CliError> {
        let guard = self
            .guard
            .take()
            .expect("run guard is present until finalize");
        guard.finalize(outcome, error).await
    }

    async fn record_stage(
        &self,
        sequence: u64,
        stage: &str,
        stage_state: &str,
        summary: Option<String>,
        payload: Option<Value>,
    ) -> Result<(), CliError> {
        let now = chrono::Utc::now();
        let record = TaskBoardAutomationRunStage {
            sequence,
            stage: stage.to_owned(),
            state: stage_state.to_owned(),
            recorded_at: now.to_rfc3339(),
            summary,
            payload,
        };
        self.db
            .upsert_task_board_automation_run_stage(self.guard().lease(), &record, now)
            .await
            .map(|_| ())
    }

    fn guard(&self) -> &TaskBoardOrchestratorRunGuard {
        self.guard
            .as_ref()
            .expect("run guard is present until finalize")
    }
}

#[cfg(test)]
mod tests {
    use sqlx::query_scalar;

    use super::*;
    use crate::task_board::TaskBoardAutomationDesiredMode;

    async fn database() -> AsyncDaemonDb {
        let temp = tempfile::tempdir().expect("temp dir");
        let path = temp.keep().join("harness.db");
        AsyncDaemonDb::connect(&path).await.expect("open database")
    }

    #[tokio::test]
    async fn session_persists_fenced_stages_and_correlated_audit_events() {
        let db = database().await;
        db.start_task_board_automation(
            TaskBoardAutomationDesiredMode::Continuous,
            chrono::Utc::now(),
        )
        .await
        .expect("start automation");
        let start = TaskBoardAutomationRunSession::acquire(
            &db,
            TaskBoardAutomationRunTrigger::Manual,
            Some("operator".into()),
            false,
            TaskBoardAutomationScope {
                item_id: Some("item-neutral".into()),
                ..TaskBoardAutomationScope::default()
            },
        )
        .await
        .expect("acquire run");
        let TaskBoardAutomationRunStart::Acquired(session) = start else {
            panic!("manual run should be admitted");
        };
        let session = *session;
        let run_id = session.run_id().to_owned();

        session
            .begin_stage(1, "prepare", None, None)
            .await
            .expect("begin stage");
        session
            .complete_stage(1, "prepare", Some("ready".into()), None)
            .await
            .expect("complete stage");
        session
            .finalize(TaskBoardAutomationRunOutcome::Completed, None)
            .await
            .expect("finalize run");

        let state = query_scalar::<_, String>(
            "SELECT state FROM task_board_orchestrator_runs WHERE run_id = ?1",
        )
        .bind(&run_id)
        .fetch_one(db.pool())
        .await
        .expect("load run state");
        assert_eq!(state, "terminal");
        let audit_count =
            query_scalar::<_, i64>("SELECT COUNT(*) FROM audit_events WHERE correlation_id = ?1")
                .bind(&run_id)
                .fetch_one(db.pool())
                .await
                .expect("count correlated audits");
        assert_eq!(audit_count, 4);
    }
}
