use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    TaskBoardExecutionPhase, TaskBoardStatus, TaskBoardWorkflowExecutionRecord,
};

use super::super::task_board_read_only_coordinator::reconcile_task_board_read_only_workflows_with_runtime;
use super::super::task_board_read_only_runtime::TaskBoardReadOnlyRuntime;
use super::fixture::Fixture;

pub(super) struct HeadlessWorkflowDriver<'a, R> {
    fixture: &'a Fixture,
    runtime: &'a R,
}

impl<'a, R: TaskBoardReadOnlyRuntime> HeadlessWorkflowDriver<'a, R> {
    pub(super) fn new(fixture: &'a Fixture, runtime: &'a R) -> Self {
        Self { fixture, runtime }
    }

    pub(super) async fn tick(&self, now: &str) {
        let db = self.restart(now).await;
        db.pool().close().await;
    }

    pub(super) async fn drive_to_phase(
        &self,
        phase: TaskBoardExecutionPhase,
        now: &str,
        max_ticks: usize,
    ) {
        for _ in 0..max_ticks {
            let db = self.restart(now).await;
            let reached_phase = self.execution(&db).await.transition.phase == Some(phase);
            db.pool().close().await;
            if reached_phase {
                return;
            }
        }
        let execution = self.persisted_execution().await;
        panic!(
            "workflow {} did not reach {phase:?}; stage={:?}; state={:?}; evidence={:?}",
            execution.execution_id,
            execution.transition.phase,
            execution.transition.execution_state,
            execution.artifacts.diagnostics
        );
    }

    pub(super) async fn drive_to_terminal_projection(&self, now: &str, max_ticks: usize) {
        for _ in 0..max_ticks {
            let db = self.restart(now).await;
            let projected = db
                .task_board_item_snapshot(&self.fixture.item_id)
                .await
                .expect("load workflow driver item")
                .item
                .status
                == TaskBoardStatus::Done;
            db.pool().close().await;
            if projected {
                return;
            }
        }
        let execution = self.persisted_execution().await;
        panic!(
            "workflow {} did not project terminal state; stage={:?}; state={:?}; evidence={:?}",
            execution.execution_id,
            execution.transition.phase,
            execution.transition.execution_state,
            execution.artifacts.diagnostics
        );
    }

    async fn persisted_execution(&self) -> TaskBoardWorkflowExecutionRecord {
        let db = self.connect().await;
        let execution = self.execution(&db).await;
        db.pool().close().await;
        execution
    }

    async fn execution(&self, db: &AsyncDaemonDb) -> TaskBoardWorkflowExecutionRecord {
        db.task_board_workflow_execution(&self.fixture.execution_id)
            .await
            .expect("load workflow driver execution")
            .expect("workflow driver execution exists")
    }

    async fn restart(&self, now: &str) -> AsyncDaemonDb {
        let db = self.connect().await;
        self.reconcile(&db, now).await;
        db
    }

    async fn connect(&self) -> AsyncDaemonDb {
        AsyncDaemonDb::connect(&self.fixture.test.path)
            .await
            .expect("restart workflow driver database")
    }

    async fn reconcile(&self, db: &AsyncDaemonDb, now: &str) {
        let report =
            reconcile_task_board_read_only_workflows_with_runtime(db, self.runtime, now, 8)
                .await
                .expect("reconcile headless workflow");
        if !report.failures.is_empty() {
            let execution = db
                .task_board_workflow_execution(&self.fixture.execution_id)
                .await
                .expect("load failed workflow")
                .expect("failed workflow exists");
            panic!(
                "workflow {} failed at {:?}: {:?}; evidence={:?}",
                execution.execution_id,
                execution.transition.phase,
                report.failures,
                execution.artifacts.diagnostics
            );
        }
    }
}
