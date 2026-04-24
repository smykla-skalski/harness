use super::{
    CONTROL_PLANE_ACTOR_ID, SessionSignalRecord, SessionSignalStatus, SessionState, TaskStatus,
    build_signal,
};
use crate::session::types::SessionRole;

pub(crate) const SPAWN_REVIEWER_COMMAND: &str = "spawn_reviewer";
const SPAWN_REVIEWER_MESSAGE: &str =
    "Task awaiting review has no reviewers; spawn a reviewer to unblock the queue.";
const SPAWN_REVIEWER_ACTION_HINT: &str = "harness:session:spawn-reviewer";

/// Build a `spawn_reviewer` signal aimed at the session leader when the
/// given task is `AwaitingReview` and the session currently has no
/// reviewer-role agent that can take the claim.
///
/// Returns `None` when the task is not awaiting review, already has a
/// reviewer available, has no leader to receive the signal, or cannot
/// be located.
pub(crate) fn maybe_emit_spawn_reviewer(
    state: &SessionState,
    task_id: &str,
    now: &str,
) -> Option<SessionSignalRecord> {
    let task = state.tasks.get(task_id)?;
    if task.status != TaskStatus::AwaitingReview {
        return None;
    }
    let has_reviewer = state
        .agents
        .values()
        .any(|agent| agent.role == SessionRole::Reviewer && agent.status.accepts_assignment());
    if has_reviewer {
        return None;
    }
    let leader_id = state.leader_id.as_deref()?;
    let leader = state.agents.get(leader_id)?;
    Some(SessionSignalRecord {
        runtime: leader.runtime.clone(),
        agent_id: leader.agent_id.clone(),
        session_id: state.session_id.clone(),
        status: SessionSignalStatus::Pending,
        signal: build_signal(
            CONTROL_PLANE_ACTOR_ID,
            SPAWN_REVIEWER_COMMAND,
            SPAWN_REVIEWER_MESSAGE,
            Some(SPAWN_REVIEWER_ACTION_HINT),
            &state.session_id,
            &leader.agent_id,
            now,
        ),
        acknowledgment: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::types::{
        AgentRegistration, AgentStatus, AwaitingReview, SessionMetrics, SessionPolicy, SessionRole,
        SessionState, SessionStatus, TaskSeverity, TaskSource, TaskStatus, WorkItem,
    };
    use std::collections::BTreeMap;
    use std::path::PathBuf;

    fn base_state() -> SessionState {
        SessionState {
            schema_version: 10,
            state_version: 1,
            session_id: "sess-1".to_string(),
            project_name: String::new(),
            worktree_path: PathBuf::new(),
            shared_path: PathBuf::new(),
            origin_path: PathBuf::new(),
            branch_ref: "harness/sess-1".to_string(),
            title: "t".to_string(),
            context: "c".to_string(),
            status: SessionStatus::Active,
            policy: SessionPolicy::default(),
            created_at: "now".to_string(),
            updated_at: "now".to_string(),
            agents: BTreeMap::new(),
            tasks: BTreeMap::new(),
            leader_id: Some("claude-leader".to_string()),
            archived_at: None,
            last_activity_at: None,
            observe_id: None,
            pending_leader_transfer: None,
            external_origin: None,
            adopted_at: None,
            metrics: SessionMetrics::default(),
        }
    }

    fn make_agent(id: &str, runtime: &str, role: SessionRole) -> AgentRegistration {
        AgentRegistration {
            agent_id: id.to_string(),
            name: id.to_string(),
            runtime: runtime.to_string(),
            role,
            capabilities: Vec::new(),
            joined_at: "now".to_string(),
            updated_at: "now".to_string(),
            status: AgentStatus::Active,
            agent_session_id: None,
            last_activity_at: None,
            current_task_id: None,
            runtime_capabilities: Default::default(),
            persona: None,
        }
    }

    fn leader(state: &mut SessionState) {
        state.agents.insert(
            "claude-leader".to_string(),
            make_agent("claude-leader", "claude", SessionRole::Leader),
        );
    }

    fn awaiting_review_task(state: &mut SessionState) {
        state.tasks.insert(
            "task-1".to_string(),
            WorkItem {
                task_id: "task-1".to_string(),
                title: "t".to_string(),
                context: None,
                severity: TaskSeverity::Medium,
                status: TaskStatus::AwaitingReview,
                assigned_to: None,
                queue_policy: Default::default(),
                queued_at: None,
                created_at: "now".to_string(),
                updated_at: "now".to_string(),
                created_by: None,
                notes: Vec::new(),
                suggested_fix: None,
                source: TaskSource::default(),
                observe_issue_id: None,
                blocked_reason: None,
                completed_at: None,
                checkpoint_summary: None,
                awaiting_review: Some(AwaitingReview {
                    queued_at: "now".to_string(),
                    submitter_agent_id: "codex-worker".to_string(),
                    summary: None,
                    required_consensus: 2,
                }),
                review_claim: None,
                consensus: None,
                review_history: Vec::new(),
                review_round: 0,
                arbitration: None,
                suggested_persona: None,
            },
        );
    }

    #[test]
    fn emits_signal_when_awaiting_review_with_no_reviewer() {
        let mut state = base_state();
        leader(&mut state);
        awaiting_review_task(&mut state);

        let record = maybe_emit_spawn_reviewer(&state, "task-1", "now").expect("emit");
        assert_eq!(record.agent_id, "claude-leader");
        assert_eq!(record.signal.command, SPAWN_REVIEWER_COMMAND);
    }

    #[test]
    fn returns_none_when_reviewer_already_present() {
        let mut state = base_state();
        leader(&mut state);
        awaiting_review_task(&mut state);
        state.agents.insert(
            "gemini-reviewer".to_string(),
            make_agent("gemini-reviewer", "gemini", SessionRole::Reviewer),
        );

        assert!(maybe_emit_spawn_reviewer(&state, "task-1", "now").is_none());
    }

    #[test]
    fn returns_none_when_task_not_awaiting_review() {
        let mut state = base_state();
        leader(&mut state);
        awaiting_review_task(&mut state);
        state.tasks.get_mut("task-1").unwrap().status = TaskStatus::InProgress;
        assert!(maybe_emit_spawn_reviewer(&state, "task-1", "now").is_none());
    }
}
