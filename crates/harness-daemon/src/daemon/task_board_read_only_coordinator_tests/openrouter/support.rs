use crate::daemon::db::AgentTurnRunStatus;
use crate::task_board::TaskBoardWorkflowExecutionRecord;

use super::super::fixture::{Fixture, RETRY_AT};
use super::super::runtime::FakeReadOnlyRuntime;
use crate::daemon::db::prelude::*;
use crate::daemon::db::task_board::prelude::*;
use crate::daemon::db_handle::AsyncDaemonDbHandle;

pub(super) async fn reconcile(db: &AsyncDaemonDbHandle, runtime: &FakeReadOnlyRuntime, now: &str) {
    let report = super::super::super::task_board_read_only_coordinator::
        reconcile_task_board_read_only_workflows_with_runtime(db, runtime, now, 8)
            .await
            .expect("reconcile agent-turn workflow");
    assert!(report.failures.is_empty(), "{:?}", report.failures);
}

pub(super) async fn load(
    fixture: &Fixture,
    db: &AsyncDaemonDbHandle,
) -> TaskBoardWorkflowExecutionRecord {
    db.task_board_workflow_execution(&fixture.execution_id)
        .await
        .expect("load execution")
        .expect("execution exists")
}

pub(super) async fn finish_run(
    db: &AsyncDaemonDbHandle,
    run_id: &str,
    status: AgentTurnRunStatus,
    report: Option<&str>,
    detail: Option<&str>,
) {
    let mut run = db
        .agent_turn_run(run_id)
        .await
        .expect("load agent-turn run")
        .expect("agent-turn run exists");
    run.status = status;
    run.actual_model = Some("deepseek/deepseek-v4-flash".into());
    run.report = report.map(str::to_owned);
    match status {
        AgentTurnRunStatus::Failed => run.error = detail.map(str::to_owned),
        AgentTurnRunStatus::Cancelled => run.stop_reason = detail.map(str::to_owned),
        _ => {}
    }
    run.updated_at = RETRY_AT.into();
    db.save_agent_turn_run(&run)
        .await
        .expect("save terminal agent-turn run");
}
