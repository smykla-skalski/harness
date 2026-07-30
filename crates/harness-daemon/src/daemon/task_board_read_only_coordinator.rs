use std::collections::BTreeSet;

use chrono::Utc;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::DaemonHttpState;
use crate::task_board::TaskBoardWorkflowExecutionRecord;
use crate::task_board::task_board_remote_execution_target;
use harness_kernel::errors::CliError;

use super::task_board_read_only_runtime::{
    ProductionTaskBoardReadOnlyRuntime, TaskBoardReadOnlyRuntime,
};

mod attempt_recovery;
mod attempts;
mod in_progress;
mod ingestion;
mod lifecycle;
mod non_codex_reports;
mod report_evidence;
mod report_starts;
mod reports;
pub(crate) mod requests;
mod review_report_retention;
mod revision_validation;

const MAX_RECONCILIATIONS_PER_CLASS_PER_TICK: usize = 16;

#[derive(Debug, Default)]
pub(super) struct TaskBoardReadOnlyReconcileReport {
    pub(super) processed: usize,
    pub(super) projected: usize,
    pub(super) released_orphans: usize,
    pub(super) failures: Vec<String>,
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion inflates the score; tokio-rs/tracing#553"
)]
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

#[expect(
    clippy::cognitive_complexity,
    reason = "sequential project/recoverable/ready passes, each already its own helper"
)]
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
    execution: TaskBoardWorkflowExecutionRecord,
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
    if task_board_remote_execution_target(&execution).is_some() {
        return;
    }
    report.processed += 1;
    if let Err(error) = Box::pin(attempts::reconcile_execution(db, runtime, execution, now)).await {
        report
            .failures
            .push(format!("execution '{execution_id}' failed: {error}"));
    }
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
