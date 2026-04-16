use std::collections::BTreeMap;

use super::test_support::{agent_registration, persona, session_state, work_item};
use super::{
    AgentStatus, AutoPromotionPolicy, LeaderJoinPolicy, LeaderRecoveryPolicy, SessionMetrics,
    SessionPolicy, SessionRole, SessionState, SessionStatus, TaskCheckpointSummary, TaskNote,
    TaskQueuePolicy, TaskSeverity, TaskStatus,
};

#[test]
fn session_state_serde_round_trip() {
    let mut state = session_state(BTreeMap::new(), BTreeMap::new());
    state.session_id = "sess-test".into();
    state.title = "test session".into();
    state.context = "test goal".into();
    state.leader_id = Some("agent-1".into());
    state.last_activity_at = Some("2026-03-28T12:00:00Z".into());
    state.observe_id = Some("observe-sess-test".into());

    let json = serde_json::to_string(&state).expect("serializes");
    let parsed: SessionState = serde_json::from_str(&json).expect("deserializes");
    assert_eq!(parsed.session_id, "sess-test");
    assert_eq!(parsed.status, SessionStatus::Active);
    assert_eq!(parsed.leader_id, Some("agent-1".into()));
    assert_eq!(parsed.observe_id.as_deref(), Some("observe-sess-test"));
}

#[test]
fn session_state_without_title_deserializes_with_empty_default() {
    let json = r#"{
        "schema_version": 3,
        "session_id": "old-sess",
        "context": "legacy goal",
        "status": "active",
        "created_at": "2026-01-01T00:00:00Z",
        "updated_at": "2026-01-01T00:00:00Z"
    }"#;
    let state: SessionState = serde_json::from_str(json).expect("deserializes");
    assert_eq!(state.session_id, "old-sess");
    assert_eq!(state.title, "");
    assert_eq!(state.context, "legacy goal");
}

#[test]
fn session_state_round_trip_preserves_policy_and_leaderless_degraded_status() {
    let mut state = session_state(BTreeMap::new(), BTreeMap::new());
    state.session_id = "swarm-policy".into();
    state.status = SessionStatus::LeaderlessDegraded;
    state.policy = SessionPolicy {
        leader_join: LeaderJoinPolicy {
            require_explicit_fallback_role: true,
        },
        auto_promotion: AutoPromotionPolicy {
            role_order: vec![
                SessionRole::Improver,
                SessionRole::Reviewer,
                SessionRole::Observer,
                SessionRole::Worker,
            ],
            priority_preset_id: "swarm-default".into(),
        },
        degraded_recovery: LeaderRecoveryPolicy {
            preset_id: Some("swarm-default".into()),
            manual_recovery_allowed: true,
        },
    };

    let json = serde_json::to_string(&state).expect("serialize");
    let parsed: SessionState = serde_json::from_str(&json).expect("deserialize");

    assert_eq!(parsed.status, SessionStatus::LeaderlessDegraded);
    assert_eq!(
        parsed.policy.auto_promotion.role_order,
        vec![
            SessionRole::Improver,
            SessionRole::Reviewer,
            SessionRole::Observer,
            SessionRole::Worker,
        ]
    );
    assert_eq!(
        parsed.policy.degraded_recovery.preset_id.as_deref(),
        Some("swarm-default")
    );
}

#[test]
fn session_metrics_recalculate_counts_agents_and_tasks() {
    let mut tasks = BTreeMap::new();
    tasks.insert(
        "task-1".into(),
        work_item("task-1", "one", TaskSeverity::Medium, TaskStatus::Open),
    );

    let mut completed = work_item("task-2", "two", TaskSeverity::Medium, TaskStatus::Done);
    completed.completed_at = Some("2026-03-28T12:03:00Z".into());
    tasks.insert("task-2".into(), completed);

    let mut agents = BTreeMap::new();
    agents.insert(
        "a1".into(),
        agent_registration(
            "a1",
            "codex",
            super::SessionRole::Leader,
            AgentStatus::Active,
        ),
    );

    let metrics = SessionMetrics::recalculate(&session_state(agents, tasks));
    assert_eq!(metrics.agent_count, 1);
    assert_eq!(metrics.active_agent_count, 1);
    assert_eq!(metrics.open_task_count, 1);
    assert_eq!(metrics.completed_task_count, 1);
}

#[test]
fn metrics_exclude_idle_from_active_count() {
    let mut agents = BTreeMap::new();
    agents.insert(
        "leader".into(),
        agent_registration(
            "leader",
            "claude",
            super::SessionRole::Leader,
            AgentStatus::Active,
        ),
    );
    agents.insert(
        "idle-worker".into(),
        agent_registration(
            "idle-worker",
            "codex",
            super::SessionRole::Worker,
            AgentStatus::Idle,
        ),
    );
    agents.insert(
        "dead-worker".into(),
        agent_registration(
            "dead-worker",
            "codex",
            super::SessionRole::Worker,
            AgentStatus::Disconnected,
        ),
    );

    let metrics = SessionMetrics::recalculate(&session_state(agents, BTreeMap::new()));
    assert_eq!(metrics.agent_count, 2);
    assert_eq!(
        metrics.active_agent_count, 1,
        "only Active counts, not Idle"
    );
    assert_eq!(metrics.idle_agent_count, 1);
}

#[test]
fn session_state_round_trip_preserves_persona_tasks_and_metrics() {
    let mut agents = BTreeMap::new();
    let mut leader = agent_registration(
        "leader",
        "codex",
        super::SessionRole::Leader,
        AgentStatus::Active,
    );
    leader.capabilities = vec!["review".into()];
    leader.agent_session_id = Some("agent-session-1".into());
    leader.last_activity_at = Some("2026-03-28T12:02:00Z".into());
    leader.current_task_id = Some("task-1".into());
    leader.persona = Some(persona("code-reviewer"));
    agents.insert("leader".into(), leader);
    agents.insert(
        "observer".into(),
        agent_registration(
            "observer",
            "claude",
            super::SessionRole::Observer,
            AgentStatus::Idle,
        ),
    );

    let mut tasks = BTreeMap::new();
    let mut review = work_item(
        "task-1",
        "review websocket split",
        TaskSeverity::High,
        TaskStatus::InReview,
    );
    review.context = Some("verify the protocol modules still round-trip".into());
    review.assigned_to = Some("leader".into());
    review.queue_policy = TaskQueuePolicy::ReassignWhenFree;
    review.queued_at = Some("2026-03-28T12:01:00Z".into());
    review.updated_at = "2026-03-28T12:03:00Z".into();
    review.created_by = Some("leader".into());
    review.notes = vec![TaskNote {
        timestamp: "2026-03-28T12:02:30Z".into(),
        agent_id: Some("leader".into()),
        text: "Ready for review".into(),
    }];
    review.suggested_fix = Some("keep the public re-exports stable".into());
    review.checkpoint_summary = Some(TaskCheckpointSummary {
        checkpoint_id: "cp-1".into(),
        recorded_at: "2026-03-28T12:02:00Z".into(),
        actor_id: Some("leader".into()),
        summary: "Split complete".into(),
        progress: 80,
    });
    tasks.insert("task-1".into(), review);

    let mut state = session_state(agents, tasks);
    state.state_version = 7;
    state.session_id = "sess-99".into();
    state.title = "type split".into();
    state.context = "preserve public API".into();
    state.updated_at = "2026-03-28T12:03:00Z".into();
    state.last_activity_at = Some("2026-03-28T12:03:00Z".into());
    state.observe_id = Some("observe-sess-99".into());

    let json = serde_json::to_string(&state).expect("serializes");
    let parsed: SessionState = serde_json::from_str(&json).expect("deserializes");
    let metrics = SessionMetrics::recalculate(&parsed);

    assert_eq!(metrics.agent_count, 2);
    assert_eq!(metrics.active_agent_count, 1);
    assert_eq!(metrics.idle_agent_count, 1);
    assert_eq!(metrics.in_progress_task_count, 1);
    assert_eq!(
        parsed
            .agents
            .get("leader")
            .and_then(|agent| agent.persona.as_ref())
            .map(|persona| persona.identifier.as_str()),
        Some("code-reviewer")
    );
    assert_eq!(
        parsed
            .tasks
            .get("task-1")
            .and_then(|task| task.checkpoint_summary.as_ref())
            .map(|checkpoint| checkpoint.progress),
        Some(80)
    );
}
