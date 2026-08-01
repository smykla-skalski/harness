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
    let run_ids = execution
        .attempts
        .iter()
        .map(|attempt| attempt.idempotency_key.as_str())
        .collect::<Vec<_>>();
    let codex_runs = db
        .codex_runs_by_ids(&run_ids)
        .await?
        .into_iter()
        .map(|run| (run.run_id.clone(), run))
        .collect::<BTreeMap<_, _>>();
    let agent_turn_runs = db
        .agent_turn_runs_by_ids(&run_ids)
        .await?
        .into_iter()
        .map(|run| (run.run_id.clone(), run))
        .collect::<BTreeMap<_, _>>();
    let mut evidence = BTreeMap::new();
    for attempt in &execution.attempts {
        if let Some(run) = codex_runs.get(&attempt.idempotency_key) {
            if matching_run_binding(
                run.workflow_execution_id.as_deref(),
                execution_id,
                &attempt.idempotency_key,
            )? {
                evidence.insert(attempt.idempotency_key.clone(), codex_evidence(run));
            }
        } else if let Some(run) = agent_turn_runs.get(&attempt.idempotency_key)
            && matching_run_binding(
                run.workflow_execution_id.as_deref(),
                execution_id,
                &attempt.idempotency_key,
            )?
        {
            evidence.insert(attempt.idempotency_key.clone(), agent_turn_evidence(run));
        }
    }
    Ok(TaskBoardWorkflowProgressResponse {
        progress: Some(build_task_board_workflow_progress(&execution, &evidence)),
    })
}

fn matching_run_binding(
    bound_execution_id: Option<&str>,
    expected_execution_id: &str,
    run_id: &str,
) -> Result<bool, CliError> {
    match bound_execution_id {
        Some(bound_execution_id) if bound_execution_id == expected_execution_id => Ok(true),
        None => Ok(false),
        Some(_) => Err(CliErrorKind::workflow_io(format!(
            "workflow attempt run '{run_id}' is not bound to execution '{expected_execution_id}'"
        ))
        .into()),
    }
}

fn codex_evidence(run: &CodexRunSnapshot) -> TaskBoardWorkflowAttemptRuntimeEvidence {
    TaskBoardWorkflowAttemptRuntimeEvidence {
        runtime: "codex".into(),
        model: run.model.clone(),
        report: run
            .final_message
            .clone()
            .or_else(|| run.latest_summary.clone()),
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

#[cfg(test)]
mod tests {
    use super::matching_run_binding;

    #[test]
    fn exact_run_binding_includes_runtime_evidence() {
        assert!(matching_run_binding(Some("execution-1"), "execution-1", "run-1").unwrap());
    }

    #[test]
    fn missing_run_binding_omits_legacy_runtime_evidence() {
        assert!(!matching_run_binding(None, "execution-1", "run-1").unwrap());
    }

    #[test]
    fn different_run_binding_rejects_runtime_evidence() {
        assert!(matching_run_binding(Some("execution-2"), "execution-1", "run-1").is_err());
    }
}
