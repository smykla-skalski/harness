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
        self.reconcile(&self.fixture.test.db, now).await;
    }

    pub(super) async fn restart_and_tick(&self, now: &str) {
        let db = AsyncDaemonDb::connect(&self.fixture.test.path)
            .await
            .expect("restart workflow driver database");
        self.reconcile(&db, now).await;
    }

    pub(super) async fn drive_to_phase(
        &self,
        phase: TaskBoardExecutionPhase,
        now: &str,
        max_ticks: usize,
    ) {
        for _ in 0..max_ticks {
            self.restart_and_tick(now).await;
            if self.execution().await.transition.phase == Some(phase) {
                return;
            }
        }
        let execution = self.execution().await;
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
            self.restart_and_tick(now).await;
            let item = self
                .fixture
                .test
                .db
                .task_board_item_snapshot(&self.fixture.item_id)
                .await
                .expect("load workflow driver item");
            if item.item.status == TaskBoardStatus::Done {
                return;
            }
        }
        let execution = self.execution().await;
        panic!(
            "workflow {} did not project terminal state; stage={:?}; state={:?}; evidence={:?}",
            execution.execution_id,
            execution.transition.phase,
            execution.transition.execution_state,
            execution.artifacts.diagnostics
        );
    }

    pub(super) async fn execution(&self) -> TaskBoardWorkflowExecutionRecord {
        self.fixture
            .test
            .db
            .task_board_workflow_execution(&self.fixture.execution_id)
            .await
            .expect("load workflow driver execution")
            .expect("workflow driver execution exists")
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
