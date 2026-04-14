use std::collections::BTreeMap;

use crate::agents::runtime::RuntimeCapabilities;
use crate::session::types::{
    AgentRegistration, AgentStatus, CURRENT_VERSION, SessionMetrics, SessionRole, SessionState,
    SessionStatus, TaskQueuePolicy, TaskSeverity, TaskSource, TaskStatus, WorkItem,
};

pub(super) fn sample_state(session_id: &str) -> SessionState {
    SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 0,
        session_id: session_id.to_string(),
        title: "test title".into(),
        context: "test".into(),
        status: SessionStatus::Active,
        created_at: "2026-01-01T00:00:00Z".into(),
        updated_at: "2026-01-01T00:00:00Z".into(),
        agents: BTreeMap::from([(
            "claude-leader".into(),
            AgentRegistration {
                agent_id: "claude-leader".into(),
                name: "claude leader".into(),
                runtime: "claude".into(),
                role: SessionRole::Leader,
                capabilities: Vec::new(),
                joined_at: "2026-01-01T00:00:00Z".into(),
                updated_at: "2026-01-01T00:00:00Z".into(),
                status: AgentStatus::Active,
                agent_session_id: None,
                last_activity_at: Some("2026-01-01T00:00:00Z".into()),
                current_task_id: None,
                runtime_capabilities: RuntimeCapabilities::default(),
                persona: None,
            },
        )]),
        tasks: BTreeMap::from([(
            "task-1".into(),
            WorkItem {
                task_id: "task-1".into(),
                title: "task".into(),
                context: None,
                severity: TaskSeverity::Medium,
                status: TaskStatus::Open,
                assigned_to: None,
                queue_policy: TaskQueuePolicy::Locked,
                queued_at: None,
                created_at: "2026-01-01T00:00:00Z".into(),
                updated_at: "2026-01-01T00:00:00Z".into(),
                created_by: None,
                notes: Vec::new(),
                suggested_fix: None,
                source: TaskSource::Manual,
                blocked_reason: None,
                completed_at: None,
                checkpoint_summary: None,
            },
        )]),
        leader_id: Some("claude-leader".into()),
        archived_at: None,
        last_activity_at: Some("2026-01-01T00:00:00Z".into()),
        observe_id: Some(format!("observe-{session_id}")),
        pending_leader_transfer: None,
        metrics: SessionMetrics::default(),
    }
}
