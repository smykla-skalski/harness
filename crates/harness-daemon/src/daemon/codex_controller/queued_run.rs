use crate::agents::turn::AgentTurnPullRequest;
use crate::daemon::protocol::{CodexRunRequest, CodexRunSnapshot, CodexRunStatus};
use crate::workspace::utc_now;

pub(super) struct QueuedRunIdentity {
    run_id: String,
    project_dir: String,
    session_agent_id: Option<String>,
    display_name: String,
}

impl QueuedRunIdentity {
    pub(super) fn for_session(
        run_id: String,
        project_dir: String,
        session_agent_id: String,
        display_name: String,
    ) -> Self {
        Self {
            run_id,
            project_dir,
            session_agent_id: Some(session_agent_id),
            display_name,
        }
    }

    pub(super) fn standalone(run_id: String, project_dir: String, display_name: String) -> Self {
        Self {
            run_id,
            project_dir,
            session_agent_id: None,
            display_name,
        }
    }
}

pub(super) fn queued_run_snapshot(
    session_id: &str,
    request: &CodexRunRequest,
    prompt: &str,
    identity: QueuedRunIdentity,
    pull_request: Option<&AgentTurnPullRequest>,
) -> CodexRunSnapshot {
    let now = utc_now();
    let mut snapshot = CodexRunSnapshot {
        run_id: identity.run_id,
        session_id: session_id.to_string(),
        task_id: request.task_id.clone(),
        board_item_id: request.board_item_id.clone(),
        workflow_execution_id: request.workflow_execution_id.clone(),
        session_agent_id: identity.session_agent_id,
        display_name: Some(identity.display_name),
        project_dir: identity.project_dir,
        thread_id: request.resume_thread_id.clone(),
        turn_id: None,
        mode: request.mode,
        status: CodexRunStatus::Queued,
        prompt: prompt.to_string(),
        latest_summary: request
            .actor
            .as_ref()
            .map(|actor| format!("Queued by {actor}")),
        final_message: None,
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: now.clone(),
        updated_at: now,
        model: non_empty_owned(request.model.as_deref()),
        effort: non_empty_owned(request.effort.as_deref()),
    };
    super::completion_evidence::record_clean_worktree_baseline(&mut snapshot);
    super::turn_source::record_bound_pull_request(&mut snapshot, pull_request);
    snapshot
}

fn non_empty_owned(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}
