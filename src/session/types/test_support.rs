use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::agents::kind::RuntimeKind;
use crate::agents::runtime::RuntimeCapabilities;

use super::{
    AgentPersona, AgentRegistration, AgentStatus, CURRENT_VERSION, PersonaSymbol, SessionMetrics,
    SessionRole, SessionState, SessionStatus, TaskQueuePolicy, TaskSeverity, TaskSource,
    TaskStatus, WorkItem,
};

pub(super) fn agent_registration(
    agent_id: &str,
    runtime: &str,
    role: SessionRole,
    status: AgentStatus,
) -> AgentRegistration {
    AgentRegistration {
        agent_id: agent_id.into(),
        name: agent_id.into(),
        runtime: RuntimeKind::from(runtime),
        role,
        capabilities: vec![],
        joined_at: "2026-03-28T12:00:00Z".into(),
        updated_at: "2026-03-28T12:00:00Z".into(),
        status,
        agent_session_id: None,
        last_activity_at: None,
        current_task_id: None,
        runtime_capabilities: RuntimeCapabilities::default(),
        persona: None,
    }
}

pub(super) fn persona(identifier: &str) -> AgentPersona {
    AgentPersona {
        identifier: identifier.into(),
        name: "Code Reviewer".into(),
        symbol: PersonaSymbol::SfSymbol {
            name: "magnifyingglass.circle.fill".into(),
        },
        description: "Reviews code for correctness".into(),
    }
}

pub(super) fn session_state(
    agents: BTreeMap<String, AgentRegistration>,
    tasks: BTreeMap<String, WorkItem>,
) -> SessionState {
    SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 1,
        session_id: "sess-1".into(),
        project_name: String::new(),
        worktree_path: PathBuf::new(),
        shared_path: PathBuf::new(),
        origin_path: PathBuf::new(),
        branch_ref: String::new(),
        title: "test title".into(),
        context: "ctx".into(),
        status: SessionStatus::Active,
        policy: Default::default(),
        created_at: "2026-03-28T12:00:00Z".into(),
        updated_at: "2026-03-28T12:00:00Z".into(),
        agents,
        tasks,
        leader_id: Some("leader".into()),
        archived_at: None,
        last_activity_at: None,
        observe_id: None,
        pending_leader_transfer: None,
        external_origin: None,
        adopted_at: None,
        metrics: SessionMetrics::default(),
    }
}

pub(super) fn work_item(
    task_id: &str,
    title: &str,
    severity: TaskSeverity,
    status: TaskStatus,
) -> WorkItem {
    WorkItem {
        task_id: task_id.into(),
        title: title.into(),
        context: None,
        severity,
        status,
        assigned_to: None,
        queue_policy: TaskQueuePolicy::Locked,
        queued_at: None,
        created_at: "2026-03-28T12:00:00Z".into(),
        updated_at: "2026-03-28T12:00:00Z".into(),
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
