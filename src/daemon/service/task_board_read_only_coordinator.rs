use std::collections::BTreeSet;

use chrono::Utc;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::DaemonHttpState;
use crate::errors::CliError;

use super::task_board_read_only_runtime::{
    ProductionTaskBoardReadOnlyRuntime, TaskBoardReadOnlyRuntime,
};

mod attempt_recovery;
mod attempts;
mod ingestion;
mod lifecycle;
mod report_evidence;
mod reports;
mod requests;

const MAX_RECONCILIATIONS_PER_CLASS_PER_TICK: usize = 16;

#[derive(Debug, Default)]
pub(super) struct TaskBoardReadOnlyReconcileReport {
    pub(super) processed: usize,
    pub(super) projected: usize,
    pub(super) released_orphans: usize,
    pub(super) failures: Vec<String>,
}

pub(crate) async fn reconcile_task_board_read_only_workflows(
    state: &DaemonHttpState,
    db: &AsyncDaemonDb,
) -> Result<(), CliError> {
    let runtime = ProductionTaskBoardReadOnlyRuntime::new(state, db);
    let report = Box::pin(reconcile_task_board_read_only_workflows_with_runtime(
        db,
        &runtime,
        &Utc::now().to_rfc3339(),
        MAX_RECONCILIATIONS_PER_CLASS_PER_TICK,
    ))
    .await?;
    if report.released_orphans > 0 {
        tracing::info!(
            released_orphans = report.released_orphans,
            "released orphaned read-only workflow admission owners"
        );
    }
    for failure in report.failures {
        tracing::warn!(error = %failure, "read-only workflow reconciliation failed");
    }
    Ok(())
}

pub(super) async fn reconcile_task_board_read_only_workflows_with_runtime<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    now: &str,
    limit: usize,
) -> Result<TaskBoardReadOnlyReconcileReport, CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    let mut report = TaskBoardReadOnlyReconcileReport {
        released_orphans: db
            .recover_orphaned_task_board_read_only_workflow_admissions()
            .await?
            .len(),
        ..TaskBoardReadOnlyReconcileReport::default()
    };
    project_terminal_executions(db, limit, &mut report).await?;
    let mut seen = BTreeSet::new();
    let recoverable = db.recoverable_task_board_workflow_executions(limit).await?;
    for execution in recoverable {
        Box::pin(reconcile_candidate(
            db,
            runtime,
            execution,
            now,
            &mut seen,
            &mut report,
        ))
        .await;
    }
    for execution in db.ready_task_board_workflow_executions(now, limit).await? {
        Box::pin(reconcile_candidate(
            db,
            runtime,
            execution,
            now,
            &mut seen,
            &mut report,
        ))
        .await;
    }
    Ok(report)
}

async fn reconcile_candidate<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: crate::task_board::TaskBoardWorkflowExecutionRecord,
    now: &str,
    seen: &mut BTreeSet<String>,
    report: &mut TaskBoardReadOnlyReconcileReport,
) where
    R: TaskBoardReadOnlyRuntime,
{
    let execution_id = execution.execution_id.clone();
    if !seen.insert(execution_id.clone()) {
        return;
    }
    report.processed += 1;
    if let Err(error) = attempts::reconcile_execution(db, runtime, execution, now).await {
        report
            .failures
            .push(format!("execution '{execution_id}' failed: {error}"));
    }
}

#[cfg(test)]
pub(super) async fn reconcile_preloaded_read_only_execution<R>(
    db: &AsyncDaemonDb,
    runtime: &R,
    execution: crate::task_board::TaskBoardWorkflowExecutionRecord,
    now: &str,
) -> Result<(), CliError>
where
    R: TaskBoardReadOnlyRuntime,
{
    attempts::reconcile_execution(db, runtime, execution, now).await
}

#[cfg(test)]
pub(super) async fn settle_execution_running_in_phase_for_test(
    db: &AsyncDaemonDb,
    execution_id: &str,
    expected_phase: crate::task_board::TaskBoardExecutionPhase,
    now: &str,
) -> Result<(), CliError> {
    attempts::settle_execution_running_in_phase(db, execution_id, expected_phase, now).await
}

async fn project_terminal_executions(
    db: &AsyncDaemonDb,
    limit: usize,
    report: &mut TaskBoardReadOnlyReconcileReport,
) -> Result<(), CliError> {
    let projectable = db
        .projectable_task_board_read_only_workflow_executions(limit)
        .await?;
    for execution in projectable {
        match db
            .project_task_board_read_only_workflow_terminal(&execution.execution_id)
            .await
        {
            Ok(_) => report.projected += 1,
            Err(error) => report.failures.push(format!(
                "terminal projection '{}' failed: {error}",
                execution.execution_id
            )),
        }
    }
    Ok(())
}
