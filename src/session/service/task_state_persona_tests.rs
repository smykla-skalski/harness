use super::*;
use crate::agents::kind::RuntimeKind;
use crate::session::types::{
    AgentPersona, PersonaSymbol, SessionMetrics, SessionPolicy, SessionStatus, TaskSource,
};
use std::collections::BTreeMap;
use std::path::PathBuf;

fn persona_for(identifier: &str) -> AgentPersona {
    AgentPersona {
        identifier: identifier.to_string(),
        name: identifier.to_string(),
        symbol: PersonaSymbol::SfSymbol {
            name: "person".to_string(),
        },
        description: String::new(),
    }
}

fn agent(id: &str, persona_identifier: Option<&str>) -> AgentRegistration {
    AgentRegistration {
        agent_id: id.to_string(),
        name: id.to_string(),
        runtime: RuntimeKind::from("codex"),
        role: crate::session::types::SessionRole::Worker,
        capabilities: Vec::new(),
        joined_at: "t0".to_string(),
        updated_at: "t0".to_string(),
        status: crate::session::types::AgentStatus::Idle,
        agent_session_id: None,
        last_activity_at: Some("t0".to_string()),
        current_task_id: None,
        runtime_capabilities: Default::default(),
        persona: persona_identifier.map(persona_for),
    }
}

fn state_with_agents(agents: Vec<AgentRegistration>) -> SessionState {
    let mut map = BTreeMap::new();
    for agent in agents {
        map.insert(agent.agent_id.clone(), agent);
    }
    SessionState {
        schema_version: 10,
        state_version: 1,
        session_id: "sess".to_string(),
        project_name: String::new(),
        worktree_path: PathBuf::new(),
        shared_path: PathBuf::new(),
        origin_path: PathBuf::new(),
        branch_ref: "harness/sess".to_string(),
        title: String::new(),
        context: String::new(),
        status: SessionStatus::Active,
        policy: SessionPolicy::default(),
        created_at: "t0".to_string(),
        updated_at: "t0".to_string(),
        agents: map,
        tasks: BTreeMap::new(),
        leader_id: None,
        archived_at: None,
        last_activity_at: None,
        observe_id: None,
        pending_leader_transfer: None,
        external_origin: None,
        adopted_at: None,
        metrics: SessionMetrics::default(),
    }
}

fn queued_task(task_id: &str, suggested: Option<&str>) -> WorkItem {
    WorkItem {
        task_id: task_id.to_string(),
        title: "t".to_string(),
        context: None,
        severity: crate::session::types::TaskSeverity::Medium,
        status: TaskStatus::Open,
        assigned_to: None,
        queue_policy: TaskQueuePolicy::ReassignWhenFree,
        queued_at: Some("t0".to_string()),
        created_at: "t0".to_string(),
        updated_at: "t0".to_string(),
        created_by: None,
        notes: Vec::new(),
        suggested_fix: None,
        source: TaskSource::default(),
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
        suggested_persona: suggested.map(str::to_string),
    }
}

#[test]
fn queue_advance_picks_persona_matching_worker_over_alphabetical_order() {
    // Worker "aaa" is alphabetically first but has the wrong persona.
    // Worker "zzz" matches the task's suggested_persona. The ranker
    // must override the alphabetical default.
    let aaa = agent("aaa", Some("code-reviewer"));
    let zzz = agent("zzz", Some("test-writer"));
    let mut state = state_with_agents(vec![aaa.clone(), zzz.clone()]);
    let task = queued_task("task-a", Some("test-writer"));
    let mut reassignable = task.clone();
    reassignable.assigned_to = Some(aaa.agent_id.clone());
    state.tasks.insert(task.task_id.clone(), reassignable);

    let _effects =
        apply_advance_queued_tasks(&mut state, "leader-agent-id", "now").expect("advance");
    let after = state.tasks.get("task-a").unwrap();
    assert_eq!(
        after.assigned_to.as_deref(),
        Some("zzz"),
        "persona-matching worker must be selected over alphabetical leader"
    );
}
