use std::cmp::Reverse;

use super::{
    AgentRegistration, CliError, CliErrorKind, DEFAULT_LEADER_UNRESPONSIVE_TIMEOUT_SECONDS, Path,
    PendingLeaderTransfer, SessionRole, SessionState, SessionStatus, SessionTransition, env,
    refresh_session, require_active_target_agent, storage,
};

pub(crate) fn touch_agent(state: &mut SessionState, agent_id: &str, now: &str) {
    if let Some(agent) = state.agents.get_mut(agent_id) {
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }
}

pub(crate) fn clear_pending_leader_transfer(state: &mut SessionState, agent_id: &str) {
    if state
        .pending_leader_transfer
        .as_ref()
        .is_some_and(|request| {
            request.requested_by == agent_id
                || request.current_leader_id == agent_id
                || request.new_leader_id == agent_id
        })
    {
        state.pending_leader_transfer = None;
    }
}

pub(crate) fn leader_unresponsive_timeout_seconds() -> i64 {
    env::var("HARNESS_SESSION_LEADER_UNRESPONSIVE_TIMEOUT_SECONDS")
        .ok()
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_LEADER_UNRESPONSIVE_TIMEOUT_SECONDS)
}

pub(crate) fn agent_is_unresponsive(state: &SessionState, agent_id: &str, now: &str) -> bool {
    let Some(last_activity_at) = state
        .agents
        .get(agent_id)
        .and_then(|agent| agent.last_activity_at.as_deref())
    else {
        return true;
    };
    let Ok(now) = chrono::DateTime::parse_from_rfc3339(now) else {
        return false;
    };
    let Ok(last_activity_at) = chrono::DateTime::parse_from_rfc3339(last_activity_at) else {
        return false;
    };
    (now - last_activity_at).num_seconds() >= leader_unresponsive_timeout_seconds()
}

#[derive(Debug)]
pub(crate) struct LeaderTransferOutcome {
    pub(crate) old_leader: String,
    pub(crate) new_leader_id: String,
    pub(crate) confirmed_by: Option<String>,
    pub(crate) reason: Option<String>,
    pub(crate) log_request_before_transfer: bool,
}

#[derive(Debug)]
pub(crate) struct LeaderTransferPlan {
    pub(crate) pending_request: Option<PendingLeaderTransfer>,
    pub(crate) outcome: Option<LeaderTransferOutcome>,
}

pub(crate) fn plan_leader_transfer(
    state: &mut SessionState,
    new_leader_id: &str,
    actor_id: &str,
    reason: Option<&str>,
    now: &str,
) -> Result<LeaderTransferPlan, CliError> {
    require_active_target_agent(state, new_leader_id)?;
    let old_leader = state.leader_id.clone().unwrap_or_default();
    reject_redundant_leader_transfer(state, &old_leader, new_leader_id)?;

    if should_defer_leader_transfer(state, &old_leader, actor_id, now) {
        let request = PendingLeaderTransfer {
            requested_by: actor_id.to_string(),
            current_leader_id: old_leader,
            new_leader_id: new_leader_id.to_string(),
            requested_at: now.to_string(),
            reason: reason.map(ToString::to_string),
        };
        state.pending_leader_transfer = Some(request.clone());
        touch_agent(state, actor_id, now);
        refresh_session(state, now);
        return Ok(LeaderTransferPlan {
            pending_request: Some(request),
            outcome: None,
        });
    }

    let outcome = apply_leader_transfer(state, old_leader, new_leader_id, actor_id, reason, now);
    Ok(LeaderTransferPlan {
        pending_request: None,
        outcome: Some(outcome),
    })
}

pub(crate) fn reject_redundant_leader_transfer(
    state: &SessionState,
    old_leader: &str,
    new_leader_id: &str,
) -> Result<(), CliError> {
    if old_leader == new_leader_id {
        return Err(CliErrorKind::session_agent_conflict(format!(
            "agent '{new_leader_id}' already leads session '{}'",
            state.session_id
        ))
        .into());
    }
    Ok(())
}

pub(crate) fn should_defer_leader_transfer(
    state: &SessionState,
    old_leader: &str,
    actor_id: &str,
    now: &str,
) -> bool {
    old_leader != actor_id
        && !old_leader.is_empty()
        && !agent_is_unresponsive(state, old_leader, now)
}

pub(crate) fn apply_leader_transfer(
    state: &mut SessionState,
    old_leader: String,
    new_leader_id: &str,
    actor_id: &str,
    reason: Option<&str>,
    now: &str,
) -> LeaderTransferOutcome {
    let leader_is_actor = old_leader == actor_id;
    let prior_request = state.pending_leader_transfer.take();
    update_leader_roles(state, &old_leader, new_leader_id, now);
    state.leader_id = Some(new_leader_id.to_string());
    touch_agent(state, actor_id, now);
    refresh_session(state, now);

    LeaderTransferOutcome {
        old_leader,
        new_leader_id: new_leader_id.to_string(),
        confirmed_by: if leader_is_actor && prior_request.is_some() {
            Some(actor_id.to_string())
        } else {
            None
        },
        reason: reason
            .map(ToString::to_string)
            .or_else(|| prior_request.and_then(|request| request.reason)),
        log_request_before_transfer: !leader_is_actor,
    }
}

pub(crate) fn update_leader_roles(
    state: &mut SessionState,
    old_leader: &str,
    new_leader_id: &str,
    now: &str,
) {
    if let Some(old) = state.agents.get_mut(old_leader) {
        old.role = SessionRole::Worker;
        old.updated_at = now.to_string();
        old.last_activity_at = Some(now.to_string());
    }
    if let Some(new) = state.agents.get_mut(new_leader_id) {
        new.role = SessionRole::Leader;
        new.updated_at = now.to_string();
        new.last_activity_at = Some(now.to_string());
    }
}

fn capability_priority(agent: &AgentRegistration) -> i32 {
    agent
        .capabilities
        .iter()
        .filter_map(|capability| capability.strip_prefix("priority:"))
        .filter_map(|value| value.parse::<i32>().ok())
        .max()
        .unwrap_or_default()
}

fn promotion_key(agent: &AgentRegistration) -> (i32, Reverse<String>, Reverse<String>) {
    (
        capability_priority(agent),
        Reverse(agent.joined_at.clone()),
        Reverse(agent.agent_id.clone()),
    )
}

pub(crate) fn resolve_auto_successor(state: &SessionState) -> Option<String> {
    state
        .policy
        .auto_promotion
        .role_order
        .iter()
        .find_map(|role| {
            state
                .agents
                .values()
                .filter(|agent| agent.status.is_alive() && agent.role == *role)
                .max_by_key(|agent| promotion_key(agent))
                .map(|agent| agent.agent_id.clone())
        })
}

pub(crate) fn promote_or_degrade(state: &mut SessionState, now: &str) {
    if let Some(next_leader_id) = resolve_auto_successor(state) {
        let previous_leader = state.leader_id.clone().unwrap_or_default();
        update_leader_roles(state, &previous_leader, &next_leader_id, now);
        state.leader_id = Some(next_leader_id);
        state.status = SessionStatus::Active;
    } else {
        state.leader_id = None;
        state.status = SessionStatus::LeaderlessDegraded;
    }
}

pub(crate) fn append_leader_transfer_logs(
    project_dir: &Path,
    session_id: &str,
    actor_id: &str,
    outcome: &LeaderTransferOutcome,
) -> Result<(), CliError> {
    if outcome.log_request_before_transfer {
        storage::append_log_entry_legacy(
            project_dir,
            session_id,
            SessionTransition::LeaderTransferRequested {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
            },
            Some(actor_id),
            outcome.reason.as_deref(),
        )?;
    }
    if let Some(confirmed_by) = outcome.confirmed_by.as_deref() {
        storage::append_log_entry_legacy(
            project_dir,
            session_id,
            SessionTransition::LeaderTransferConfirmed {
                from: outcome.old_leader.clone(),
                to: outcome.new_leader_id.clone(),
                confirmed_by: confirmed_by.to_string(),
            },
            Some(confirmed_by),
            outcome.reason.as_deref(),
        )?;
    }
    storage::append_log_entry_legacy(
        project_dir,
        session_id,
        SessionTransition::LeaderTransferred {
            from: outcome.old_leader.clone(),
            to: outcome.new_leader_id.clone(),
        },
        Some(actor_id),
        outcome.reason.as_deref(),
    )?;
    Ok(())
}

pub(crate) fn clear_agent_current_task(
    state: &mut SessionState,
    agent_id: &str,
    task_id: &str,
    now: &str,
) {
    if let Some(agent) = state.agents.get_mut(agent_id)
        && agent.current_task_id.as_deref() == Some(task_id)
    {
        agent.current_task_id = None;
        agent.updated_at = now.to_string();
        agent.last_activity_at = Some(now.to_string());
    }
}
