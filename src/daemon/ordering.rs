use std::cmp::Ordering;
use std::collections::BTreeMap;

use crate::session::types::{AgentRegistration, AgentStatus, SessionRole, WorkItem};

use super::agent_tui::{AgentTuiSnapshot, AgentTuiStatus};

#[must_use]
pub const fn agent_role_priority(role: SessionRole) -> u8 {
    match role {
        SessionRole::Leader => 0,
        SessionRole::Observer => 1,
        SessionRole::Reviewer => 2,
        SessionRole::Improver => 3,
        SessionRole::Worker => 4,
    }
}

#[must_use]
pub const fn agent_status_priority(status: AgentStatus) -> u8 {
    match status {
        AgentStatus::Active => 0,
        AgentStatus::AwaitingReview => 1,
        AgentStatus::Idle => 2,
        AgentStatus::Disconnected => 3,
        AgentStatus::Removed => 4,
    }
}

#[must_use]
pub const fn agent_tui_status_priority(status: AgentTuiStatus) -> u8 {
    match status {
        AgentTuiStatus::Starting => 0,
        AgentTuiStatus::Running => 1,
        AgentTuiStatus::Stopped => 2,
        AgentTuiStatus::Exited => 3,
        AgentTuiStatus::Failed => 4,
    }
}

pub fn sort_session_agents(agents: &mut [AgentRegistration]) {
    agents.sort_unstable_by(compare_session_agents);
}

pub fn sort_session_tasks(tasks: &mut [WorkItem]) {
    tasks.sort_unstable_by(compare_work_items);
}

pub fn sort_agent_tui_snapshots(
    tuis: &mut [AgentTuiSnapshot],
    roles_by_agent: &BTreeMap<String, SessionRole>,
) {
    tuis.sort_unstable_by(|left, right| compare_agent_tui(left, right, roles_by_agent));
}

fn compare_session_agents(left: &AgentRegistration, right: &AgentRegistration) -> Ordering {
    let left_role = agent_role_priority(left.role);
    let right_role = agent_role_priority(right.role);

    left_role
        .cmp(&right_role)
        .then_with(|| agent_status_priority(left.status).cmp(&agent_status_priority(right.status)))
        .then_with(|| left.joined_at.cmp(&right.joined_at))
        .then_with(|| left.agent_id.cmp(&right.agent_id))
}

fn compare_work_items(left: &WorkItem, right: &WorkItem) -> Ordering {
    right
        .severity
        .cmp(&left.severity)
        .then_with(|| right.updated_at.cmp(&left.updated_at))
        .then_with(|| right.created_at.cmp(&left.created_at))
        .then_with(|| left.task_id.cmp(&right.task_id))
}

fn compare_agent_tui(
    left: &AgentTuiSnapshot,
    right: &AgentTuiSnapshot,
    roles_by_agent: &BTreeMap<String, SessionRole>,
) -> Ordering {
    let left_role = roles_by_agent
        .get(&left.agent_id)
        .copied()
        .unwrap_or(SessionRole::Worker);
    let right_role = roles_by_agent
        .get(&right.agent_id)
        .copied()
        .unwrap_or(SessionRole::Worker);

    agent_role_priority(left_role)
        .cmp(&agent_role_priority(right_role))
        .then_with(|| {
            agent_tui_status_priority(left.status).cmp(&agent_tui_status_priority(right.status))
        })
        .then_with(|| left.runtime.cmp(&right.runtime))
        .then_with(|| left.agent_id.cmp(&right.agent_id))
        .then_with(|| right.created_at.cmp(&left.created_at))
        .then_with(|| left.tui_id.cmp(&right.tui_id))
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use crate::session::types::{SessionRole, TaskQueuePolicy, TaskSeverity, TaskSource, WorkItem};

    use super::sort_session_tasks;

    #[test]
    fn sort_work_items_uses_deterministic_tie_breakers() {
        let mut items = vec![
            sample_task(
                "task-c",
                TaskSeverity::High,
                "2026-04-12T10:00:00Z",
                "2026-04-12T08:00:00Z",
            ),
            sample_task(
                "task-a",
                TaskSeverity::Critical,
                "2026-04-12T09:00:00Z",
                "2026-04-12T07:00:00Z",
            ),
            sample_task(
                "task-b",
                TaskSeverity::Critical,
                "2026-04-12T09:00:00Z",
                "2026-04-12T08:00:00Z",
            ),
            sample_task(
                "task-d",
                TaskSeverity::Critical,
                "2026-04-12T09:00:00Z",
                "2026-04-12T08:00:00Z",
            ),
        ];

        sort_session_tasks(&mut items);

        let order: Vec<_> = items.iter().map(|item| item.task_id.as_str()).collect();
        assert_eq!(order, vec!["task-b", "task-d", "task-a", "task-c"]);
    }

    fn sample_task(
        task_id: &str,
        severity: TaskSeverity,
        updated_at: &str,
        created_at: &str,
    ) -> WorkItem {
        WorkItem {
            task_id: task_id.to_string(),
            title: task_id.to_string(),
            context: None,
            severity,
            status: crate::session::types::TaskStatus::Open,
            assigned_to: None,
            queue_policy: TaskQueuePolicy::Locked,
            queued_at: None,
            created_at: created_at.to_string(),
            updated_at: updated_at.to_string(),
            created_by: None,
            notes: vec![],
            suggested_fix: None,
            source: TaskSource::Manual,
            observe_issue_id: None,
            blocked_reason: None,
            completed_at: None,
            checkpoint_summary: None,
            awaiting_review: None,
            review_claim: None,
            consensus: None,
            review_history: Vec::new(),
            review_round: 0,
            arbitration: None,
            suggested_persona: None,
        }
    }

    #[test]
    fn role_priority_keeps_worker_last() {
        let roles = BTreeMap::from([
            ("leader".to_string(), SessionRole::Leader),
            ("worker".to_string(), SessionRole::Worker),
        ]);
        assert_eq!(
            roles.get("leader").copied().map(super::agent_role_priority),
            Some(0)
        );
        assert_eq!(
            roles.get("worker").copied().map(super::agent_role_priority),
            Some(4)
        );
    }
}
