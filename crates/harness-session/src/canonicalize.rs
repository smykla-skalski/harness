//! Pure `SessionState` normalization: leader auto-promotion/degradation and
//! the historical-shape fix-ups applied whenever a persisted session is
//! read. This lives here rather than beside the rest of leader-transfer and
//! session-lifecycle logic in the root crate's `session::service` because
//! `index::sessions` (this crate) also needs it on every read, and `service`
//! stays in the root crate as a separate, larger extraction; `service`
//! reaches back into these functions through the root crate's
//! `pub use harness_session::*;` facade the same way it always has.

use std::cmp::Reverse;

use crate::types::{
    AgentRegistration, CURRENT_VERSION, SessionMetrics, SessionRole, SessionState, SessionStatus,
};

/// Canonicalize a persisted session that is still marked active without a
/// leader.
///
/// Historical rows can hit this shape when the leader field was missing or
/// truncated. The canonical fallback is the same logic used during live
/// leader recovery: promote a live successor if one exists, otherwise
/// degrade the session out of `active`.
pub fn canonicalize_active_session_without_leader(state: &mut SessionState, now: &str) -> bool {
    if state.status != SessionStatus::Active || state.leader_id.is_some() {
        return false;
    }

    state.schema_version = CURRENT_VERSION;
    promote_or_degrade(state, now);
    refresh_session(state, now);
    true
}

pub fn canonicalize_persisted_session_state(state: &mut SessionState, now: &str) -> bool {
    let mut changed = canonicalize_active_session_without_leader(state, now);
    if canonicalize_legacy_ended_archive_semantics(state) {
        changed = true;
    }
    changed
}

fn canonicalize_legacy_ended_archive_semantics(state: &mut SessionState) -> bool {
    if state.schema_version >= CURRENT_VERSION
        || state.status != SessionStatus::Ended
        || state.archived_at.is_none()
    {
        return false;
    }

    state.schema_version = CURRENT_VERSION;
    state.archived_at = None;
    true
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

#[must_use]
pub fn resolve_auto_successor(state: &SessionState) -> Option<String> {
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

pub fn promote_or_degrade(state: &mut SessionState, now: &str) {
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

pub fn update_leader_roles(
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

pub fn refresh_session(state: &mut SessionState, now: &str) {
    state.updated_at = now.to_string();
    state.last_activity_at = Some(now.to_string());
    state.metrics = SessionMetrics::recalculate(state);
}
