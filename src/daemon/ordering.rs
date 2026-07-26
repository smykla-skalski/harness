//! Deterministic ordering for the daemon's own agent-TUI snapshots.
//!
//! Session rosters and task queues order through `crate::session::ordering`;
//! only the terminal snapshots the daemon owns are sorted here.

use std::cmp::Ordering;
use std::collections::BTreeMap;

use crate::session::ordering::agent_role_priority;
use crate::session::types::SessionRole;

use super::agent_tui::{AgentTuiSnapshot, AgentTuiStatus};

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

pub fn sort_agent_tui_snapshots(
    tuis: &mut [AgentTuiSnapshot],
    roles_by_agent: &BTreeMap<String, SessionRole>,
) {
    tuis.sort_unstable_by(|left, right| compare_agent_tui(left, right, roles_by_agent));
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
