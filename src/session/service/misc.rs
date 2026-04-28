use super::{
    AgentRegistration, AgentStatus, BTreeMap, CliError, CliErrorKind, TaskStatus, Utc, WorkItem,
};

pub(crate) fn task_not_found(task_id: &str) -> CliError {
    CliErrorKind::session_not_active(format!("task '{task_id}' not found")).into()
}

pub(crate) fn ensure_valid_progress(progress: u8) -> Result<(), CliError> {
    if progress > 100 {
        return Err(CliErrorKind::workflow_parse(format!(
            "task checkpoint progress '{progress}' must be between 0 and 100"
        ))
        .into());
    }
    Ok(())
}

pub(crate) fn next_task_id(tasks: &BTreeMap<String, WorkItem>) -> String {
    let mut suffix = tasks.len() + 1;
    loop {
        let candidate = format!("task-{suffix}");
        if !tasks.contains_key(&candidate) {
            return candidate;
        }
        suffix += 1;
    }
}

/// Snake-case identifier used in DB rows and machine-readable contexts.
#[must_use]
pub fn agent_status_db_label(status: &AgentStatus) -> &'static str {
    match status {
        AgentStatus::Active => "active",
        AgentStatus::Idle => "idle",
        AgentStatus::AwaitingReview => "awaiting_review",
        AgentStatus::Disconnected { .. } => "disconnected",
        AgentStatus::Removed => "removed",
    }
}

pub(crate) fn agent_status_label(status: &AgentStatus) -> &'static str {
    match status {
        AgentStatus::Active => "active",
        AgentStatus::Idle => "idle",
        AgentStatus::AwaitingReview => "awaiting review",
        AgentStatus::Disconnected { .. } => "disconnected",
        AgentStatus::Removed => "removed",
    }
}

pub(crate) fn task_status_label(status: TaskStatus) -> &'static str {
    match status {
        TaskStatus::Open => "open",
        TaskStatus::InProgress => "in progress",
        TaskStatus::AwaitingReview => "awaiting review",
        TaskStatus::InReview => "in review",
        TaskStatus::Done => "done",
        TaskStatus::Blocked => "blocked",
    }
}

pub(crate) fn generate_session_id() -> String {
    format!("sess-{}", Utc::now().format("%Y%m%d%H%M%S%f"))
}

pub(crate) fn next_available_agent_id(
    runtime_name: &str,
    agents: &BTreeMap<String, AgentRegistration>,
) -> String {
    let base = format!("{runtime_name}-{}", Utc::now().format("%Y%m%d%H%M%S%f"));
    if !agents.contains_key(&base) {
        return base;
    }

    let mut suffix = 2_u32;
    loop {
        let candidate = format!("{base}-{suffix}");
        if !agents.contains_key(&candidate) {
            return candidate;
        }
        suffix += 1;
    }
}

pub(crate) fn generate_checkpoint_id(task_id: &str) -> String {
    format!("{task_id}-cp-{}", Utc::now().format("%Y%m%d%H%M%S%f"))
}

pub(crate) fn generate_review_id(task_id: &str) -> String {
    format!("{task_id}-rv-{}", Utc::now().format("%Y%m%d%H%M%S%f"))
}

pub(crate) fn generate_signal_id() -> String {
    format!("sig-{}", Utc::now().format("%Y%m%d%H%M%S%f"))
}
