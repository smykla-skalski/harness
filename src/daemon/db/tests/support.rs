use super::*;

mod extended_fixtures;
pub(super) use extended_fixtures::{
    agent_columns, median_runtime_budget_ms, sample_conversation_event, sample_resolved_session,
    seeded_performance_db, session_agent_identity_rows, simulate_pre_v11_agents_table,
};

pub(super) fn sample_signal_record(expires_at: &str) -> SessionSignalRecord {
    use crate::agents::runtime::signal::{DeliveryConfig, SignalPayload, SignalPriority};
    use serde_json::json;

    SessionSignalRecord {
        runtime: "claude".into(),
        agent_id: "claude-leader".into(),
        session_id: "sess-test-1".into(),
        status: SessionSignalStatus::Pending,
        signal: Signal {
            signal_id: "sig-test-1".into(),
            version: 1,
            created_at: "2026-04-03T12:00:00Z".into(),
            expires_at: expires_at.into(),
            source_agent: "claude".into(),
            command: "inject_context".into(),
            priority: SignalPriority::Normal,
            payload: SignalPayload {
                message: "test".into(),
                action_hint: None,
                related_files: vec![],
                metadata: json!({}),
            },
            delivery: DeliveryConfig {
                max_retries: 3,
                retry_count: 0,
                idempotency_key: None,
            },
        },
        acknowledgment: None,
    }
}
pub(super) fn sample_project() -> DiscoveredProject {
    DiscoveredProject {
        project_id: "project-abc123".into(),
        name: "harness".into(),
        project_dir: Some("/tmp/harness".into()),
        repository_root: Some("/tmp/harness".into()),
        checkout_id: "checkout-abc123".into(),
        checkout_name: "Repository".into(),
        context_root: "/tmp/data/projects/project-abc123".into(),
        is_worktree: false,
        worktree_name: None,
    }
}

pub(super) fn sample_repository_project(root: &str) -> DiscoveredProject {
    let root = PathBuf::from(root);
    let project_id = project_context_id(&root).expect("project id");
    DiscoveredProject {
        project_id: project_id.clone(),
        name: root
            .file_name()
            .map_or_else(String::new, |name| name.to_string_lossy().to_string()),
        project_dir: Some(root.clone()),
        repository_root: Some(root),
        checkout_id: project_id,
        checkout_name: "Repository".into(),
        context_root: "/tmp/data/projects/repository".into(),
        is_worktree: false,
        worktree_name: None,
    }
}

pub(super) fn sample_worktree_project(
    repository_root: &str,
    worktree_root: &str,
) -> DiscoveredProject {
    let repository_root = PathBuf::from(repository_root);
    let worktree_root = PathBuf::from(worktree_root);
    let checkout_id = project_context_id(&worktree_root).expect("checkout id");
    let name = repository_root
        .file_name()
        .map_or_else(String::new, |name| name.to_string_lossy().to_string());
    let worktree_name = worktree_root
        .file_name()
        .map_or_else(String::new, |name| name.to_string_lossy().to_string());
    DiscoveredProject {
        project_id: checkout_id.clone(),
        name,
        project_dir: Some(worktree_root),
        repository_root: Some(repository_root),
        checkout_id,
        checkout_name: worktree_name.clone(),
        context_root: "/tmp/data/projects/worktree".into(),
        is_worktree: true,
        worktree_name: Some(worktree_name),
    }
}

pub(super) fn sample_session_state() -> SessionState {
    use crate::agents::runtime::RuntimeCapabilities;
    use crate::session::types::{
        AgentRegistration, AgentStatus, SessionMetrics, SessionRole, TaskQueuePolicy, TaskSeverity,
        TaskSource, TaskStatus,
    };

    let mut agents = BTreeMap::new();
    agents.insert(
        "claude-leader".into(),
        AgentRegistration {
            agent_id: "claude-leader".into(),
            name: "Claude Leader".into(),
            runtime: "claude".into(),
            role: SessionRole::Leader,
            capabilities: vec!["general".into()],
            joined_at: "2026-04-03T12:00:00Z".into(),
            updated_at: "2026-04-03T12:05:00Z".into(),
            status: AgentStatus::Active,
            agent_session_id: Some("claude-session-1".into()),
            managed_agent: None,
            last_activity_at: Some("2026-04-03T12:05:00Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        },
    );

    let mut tasks = BTreeMap::new();
    tasks.insert(
        "task-1".into(),
        WorkItem {
            task_id: "task-1".into(),
            title: "Fix the bug".into(),
            context: Some("In module X".into()),
            severity: TaskSeverity::High,
            status: TaskStatus::Open,
            assigned_to: None,
            queue_policy: TaskQueuePolicy::Locked,
            queued_at: None,
            created_at: "2026-04-03T12:01:00Z".into(),
            updated_at: "2026-04-03T12:01:00Z".into(),
            created_by: Some("claude-leader".into()),
            notes: Vec::new(),
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
        },
    );

    SessionState {
        schema_version: 3,
        state_version: 1,
        session_id: "sess-test-1".into(),
        project_name: String::new(),
        worktree_path: PathBuf::new(),
        shared_path: PathBuf::new(),
        origin_path: PathBuf::new(),
        branch_ref: String::new(),
        title: "test title".into(),
        context: "test session".into(),
        status: SessionStatus::Active,
        policy: Default::default(),
        created_at: "2026-04-03T12:00:00Z".into(),
        updated_at: "2026-04-03T12:05:00Z".into(),
        agents,
        tasks,
        leader_id: Some("claude-leader".into()),
        archived_at: None,
        last_activity_at: Some("2026-04-03T12:05:00Z".into()),
        observe_id: None,
        pending_leader_transfer: None,
        external_origin: None,
        adopted_at: None,
        metrics: SessionMetrics::default(),
    }
}

pub(super) fn sample_session_state_with_id(session_id: &str) -> SessionState {
    let mut state = sample_session_state();
    state.session_id = session_id.to_string();
    state.title = session_id.to_string();
    state
}

pub(super) fn sample_session_state_with_managed_agents() -> SessionState {
    use crate::agents::runtime::RuntimeCapabilities;
    use crate::session::types::{
        AgentRegistration, AgentStatus, CURRENT_VERSION, ManagedAgentRef, SessionMetrics,
        SessionRole,
    };

    let mut state = sample_session_state();
    state.schema_version = CURRENT_VERSION;
    state
        .agents
        .get_mut("claude-leader")
        .expect("leader agent present")
        .managed_agent = Some(ManagedAgentRef::tui("agent-tui-1"));
    state.agents.insert(
        "acp-worker".into(),
        AgentRegistration {
            agent_id: "acp-worker".into(),
            name: "ACP Worker".into(),
            runtime: "claude".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            joined_at: "2026-04-03T12:02:00Z".into(),
            updated_at: "2026-04-03T12:06:00Z".into(),
            status: AgentStatus::Active,
            agent_session_id: Some("claude-session-2".into()),
            managed_agent: Some(ManagedAgentRef::acp("acp-agent-1")),
            last_activity_at: Some("2026-04-03T12:06:00Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        },
    );
    state.agents.insert(
        "codex-worker".into(),
        AgentRegistration {
            agent_id: "codex-worker".into(),
            name: "Codex Worker".into(),
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            joined_at: "2026-04-03T12:03:00Z".into(),
            updated_at: "2026-04-03T12:06:30Z".into(),
            status: AgentStatus::Active,
            agent_session_id: Some("codex-session-1".into()),
            managed_agent: None,
            last_activity_at: Some("2026-04-03T12:06:30Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        },
    );
    state.agents.insert(
        "unmanaged-reviewer".into(),
        AgentRegistration {
            agent_id: "unmanaged-reviewer".into(),
            name: "Unmanaged Reviewer".into(),
            runtime: "copilot".into(),
            role: SessionRole::Reviewer,
            capabilities: vec!["review".into()],
            joined_at: "2026-04-03T12:04:00Z".into(),
            updated_at: "2026-04-03T12:07:00Z".into(),
            status: AgentStatus::Idle,
            agent_session_id: Some("copilot-session-1".into()),
            managed_agent: None,
            last_activity_at: Some("2026-04-03T12:07:00Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        },
    );
    state.metrics = SessionMetrics::recalculate(&state);
    state
}

pub(super) fn sample_codex_run(run_id: &str, updated_at: &str) -> CodexRunSnapshot {
    CodexRunSnapshot {
        run_id: run_id.into(),
        session_id: "sess-test-1".into(),
        project_dir: "/tmp/harness".into(),
        thread_id: Some("thread-1".into()),
        turn_id: Some("turn-1".into()),
        mode: CodexRunMode::Approval,
        status: CodexRunStatus::Running,
        prompt: "Investigate the suite.".into(),
        latest_summary: Some("Working".into()),
        final_message: None,
        error: None,
        pending_approvals: Vec::new(),
        created_at: "2026-04-09T09:00:00Z".into(),
        updated_at: updated_at.into(),
        model: None,
        effort: None,
    }
}

pub(super) fn sample_agent_tui(tui_id: &str, updated_at: &str) -> AgentTuiSnapshot {
    AgentTuiSnapshot {
        tui_id: tui_id.into(),
        session_id: "sess-test-1".into(),
        agent_id: "claude-leader".into(),
        runtime: "copilot".into(),
        status: AgentTuiStatus::Running,
        argv: vec!["copilot".into()],
        project_dir: "/tmp/harness".into(),
        size: AgentTuiSize {
            rows: 30,
            cols: 120,
        },
        screen: TerminalScreenSnapshot {
            rows: 30,
            cols: 120,
            cursor_row: 1,
            cursor_col: 6,
            text: "ready".into(),
        },
        transcript_path: "/tmp/harness/output.raw".into(),
        exit_code: None,
        signal: None,
        error: None,
        created_at: "2026-04-09T09:00:00Z".into(),
        updated_at: updated_at.into(),
    }
}
