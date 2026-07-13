use crate::daemon::protocol::{CodexRunSnapshot, CodexRunStatus};
use crate::errors::CliError;
use crate::session::service as session_service;
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionState, TaskStatus};

const TASK_SUBMISSION_SUMMARY_LIMIT: usize = 2_000;

#[expect(
    clippy::cognitive_complexity,
    reason = "terminal task bridging keeps all manual-move guards together"
)]
pub(super) fn apply_bound_task_terminal_transition(
    state: &mut SessionState,
    run: &CodexRunSnapshot,
    now: &str,
) -> Result<bool, CliError> {
    let (Some(task_id), Some(agent_id)) = (run.task_id.as_deref(), run.session_agent_id.as_deref())
    else {
        return Ok(false);
    };
    if run.status.is_active() {
        return Ok(false);
    }
    let Some(task) = state.tasks.get(task_id) else {
        tracing::info!(
            run_id = %run.run_id,
            session_id = %run.session_id,
            task_id,
            "skipping codex task bridge because the bound task no longer exists"
        );
        return Ok(false);
    };
    if task.status != TaskStatus::InProgress || task.assigned_to.as_deref() != Some(agent_id) {
        tracing::info!(
            run_id = %run.run_id,
            session_id = %run.session_id,
            task_id,
            status = ?task.status,
            assignee = ?task.assigned_to,
            "skipping codex task bridge because the task was moved manually"
        );
        return Ok(false);
    }
    if !state
        .agents
        .get(agent_id)
        .is_some_and(|agent| agent.status.is_alive())
    {
        tracing::info!(
            run_id = %run.run_id,
            session_id = %run.session_id,
            task_id,
            agent_id,
            "skipping codex task bridge because the bound agent is gone"
        );
        return Ok(false);
    }
    match run.status {
        CodexRunStatus::Completed => {
            let summary = completion_summary(run.final_message.as_deref());
            session_service::apply_submit_for_review_for_managed_run(
                state,
                task_id,
                agent_id,
                Some(&summary),
                now,
            )?;
        }
        CodexRunStatus::Failed | CodexRunStatus::Cancelled => {
            let reason = terminal_failure_reason(run);
            session_service::apply_update_task_for_managed_run(
                state,
                task_id,
                TaskStatus::Blocked,
                Some(&reason),
                CONTROL_PLANE_ACTOR_ID,
                now,
            )?;
        }
        CodexRunStatus::Queued | CodexRunStatus::Running | CodexRunStatus::WaitingApproval => {
            return Ok(false);
        }
    }
    Ok(true)
}

fn completion_summary(final_message: Option<&str>) -> String {
    let message = final_message
        .map(str::trim)
        .filter(|message| !message.is_empty());
    truncate_chars(
        message.unwrap_or("Codex worker completed the assigned task."),
        TASK_SUBMISSION_SUMMARY_LIMIT,
    )
}

fn terminal_failure_reason(run: &CodexRunSnapshot) -> String {
    let detail = run
        .error
        .as_deref()
        .or(run.latest_summary.as_deref())
        .map(str::trim)
        .filter(|detail| !detail.is_empty())
        .unwrap_or("no failure detail was reported");
    let prefix = match run.status {
        CodexRunStatus::Cancelled => "Codex run was cancelled",
        _ => "Codex run failed",
    };
    truncate_chars(
        &format!("{prefix}: {detail}"),
        TASK_SUBMISSION_SUMMARY_LIMIT,
    )
}

fn truncate_chars(value: &str, limit: usize) -> String {
    let mut chars = value.chars();
    let truncated: String = chars.by_ref().take(limit).collect();
    if chars.next().is_some() {
        format!("{truncated}…")
    } else {
        truncated
    }
}
