use std::collections::BTreeMap;

use crate::daemon::db::{AgentTurnRunSnapshot, AsyncDaemonDb};
use crate::daemon::protocol::CodexRunSnapshot;
use crate::task_board::{
    TaskBoardWorkflowAttemptRuntimeEvidence, TaskBoardWorkflowProgressResponse,
    build_task_board_workflow_progress,
};
use harness_kernel::errors::{CliError, CliErrorKind};

use super::TaskBoardGetItemRequest;

pub(crate) async fn get_task_board_workflow_progress_db(
    db: &AsyncDaemonDb,
    request: &TaskBoardGetItemRequest,
) -> Result<TaskBoardWorkflowProgressResponse, CliError> {
    let item = db.task_board_item(&request.id).await?;
    let Some(execution_id) = item.workflow.execution_id.as_deref() else {
        return Ok(TaskBoardWorkflowProgressResponse { progress: None });
    };
    let execution = db
        .task_board_workflow_execution(execution_id)
        .await?
        .ok_or_else(|| {
            CliError::from(CliErrorKind::workflow_io(format!(
                "task-board item '{}' references missing workflow execution '{execution_id}'",
                request.id
            )))
        })?;
    let mut evidence = BTreeMap::new();
    for attempt in &execution.attempts {
        if let Some(run) = db.codex_run(&attempt.idempotency_key).await? {
            validate_run_binding(
                run.workflow_execution_id.as_deref(),
                execution_id,
                &attempt.idempotency_key,
            )?;
            evidence.insert(attempt.idempotency_key.clone(), codex_evidence(&run));
        } else if let Some(run) = db.agent_turn_run(&attempt.idempotency_key).await? {
            validate_run_binding(
                run.workflow_execution_id.as_deref(),
                execution_id,
                &attempt.idempotency_key,
            )?;
            evidence.insert(attempt.idempotency_key.clone(), agent_turn_evidence(&run));
        }
    }
    Ok(TaskBoardWorkflowProgressResponse {
        progress: Some(build_task_board_workflow_progress(&execution, &evidence)),
    })
}

fn validate_run_binding(
    bound_execution_id: Option<&str>,
    expected_execution_id: &str,
    run_id: &str,
) -> Result<(), CliError> {
    if bound_execution_id == Some(expected_execution_id) {
        return Ok(());
    }
    Err(CliErrorKind::workflow_io(format!(
        "workflow attempt run '{run_id}' is not bound to execution '{expected_execution_id}'"
    ))
    .into())
}

fn codex_evidence(run: &CodexRunSnapshot) -> TaskBoardWorkflowAttemptRuntimeEvidence {
    TaskBoardWorkflowAttemptRuntimeEvidence {
        runtime: "codex".into(),
        model: run.model.clone(),
        report: run.final_message.clone().or_else(|| run.latest_summary.clone()),
        terminal_reason: run.error.clone(),
    }
}

fn agent_turn_evidence(run: &AgentTurnRunSnapshot) -> TaskBoardWorkflowAttemptRuntimeEvidence {
    TaskBoardWorkflowAttemptRuntimeEvidence {
        runtime: run
            .actual_runtime
            .clone()
            .unwrap_or_else(|| run.requested_runtime.clone()),
        model: run
            .actual_model
            .clone()
            .or_else(|| run.requested_model.clone()),
        report: run.report.clone(),
        terminal_reason: run.error.clone().or_else(|| run.stop_reason.clone()),
    }
}
