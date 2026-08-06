use crate::daemon::protocol::{CodexRunRequest, CodexRunSnapshot, CodexRunStatus};
use crate::task_board::TaskBoardLocalAttemptResult;
use harness_kernel::errors::{CliError, CliErrorKind};

use super::super::NOW;

pub(super) fn planned_run(
    session_id: &str,
    request: &CodexRunRequest,
    run_id: &str,
    project_dir: &str,
    result: &TaskBoardLocalAttemptResult,
    status: CodexRunStatus,
) -> Result<CodexRunSnapshot, CliError> {
    Ok(CodexRunSnapshot {
        run_id: run_id.into(),
        session_id: session_id.into(),
        task_id: request.task_id.clone(),
        board_item_id: request.board_item_id.clone(),
        workflow_execution_id: request.workflow_execution_id.clone(),
        session_agent_id: Some(format!("agent-{run_id}")),
        display_name: request.name.clone(),
        project_dir: project_dir.into(),
        thread_id: Some(format!("thread-{run_id}")),
        turn_id: Some(format!("turn-{run_id}")),
        mode: request.mode,
        status,
        prompt: request.prompt.clone(),
        latest_summary: Some("report completed".into()),
        final_message: Some(serde_json::to_string(result).map_err(|error| {
            CliError::from(CliErrorKind::invalid_transition(format!(
                "serialize fake result: {error}"
            )))
        })?),
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: NOW.into(),
        updated_at: NOW.into(),
        model: request.model.clone(),
        effort: request.effort.clone(),
    })
}
