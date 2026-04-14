use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::agents::runtime::RuntimeCapabilities;
use crate::agents::runtime::signal::{
    AckResult, DeliveryConfig, Signal, SignalAck, SignalPayload, SignalPriority,
    acknowledge_signal, write_signal_file,
};
use crate::daemon::index::DiscoveredProject;
use crate::observe::types::{
    ActiveWorker, CycleRecord, FixSafety, IssueCategory, IssueCode, IssueSeverity, ObserverState,
    OpenIssue,
};
use crate::session::types::{
    AgentRegistration, AgentStatus, CURRENT_VERSION, SessionMetrics, SessionRole, SessionState,
    SessionStatus, TaskQueuePolicy, TaskSeverity, TaskSource, TaskStatus, WorkItem,
};

pub(super) const OBSERVE_ID: &str = "observe-sess-merge";

pub(super) fn write_json(path: &Path, value: &impl serde::Serialize) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create parent");
    }
    fs::write(
        path,
        serde_json::to_string_pretty(value).expect("serialize"),
    )
    .expect("write");
}

pub(super) fn write_json_line(path: &Path, value: &impl serde::Serialize) {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).expect("create parent");
    }

    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .expect("open jsonl");
    writeln!(file, "{}", serde_json::to_string(value).expect("serialize")).expect("write");
}

pub(super) fn sample_state(session_id: &str) -> SessionState {
    sample_state_for_runtime(session_id, "codex", "codex-session-1")
}

pub(super) fn sample_state_for_runtime(
    session_id: &str,
    runtime: &str,
    runtime_session_id: &str,
) -> SessionState {
    let mut agents = BTreeMap::new();
    agents.insert(
        format!("{runtime}-worker"),
        AgentRegistration {
            agent_id: format!("{runtime}-worker"),
            name: format!("{} Worker", runtime.to_uppercase()),
            runtime: runtime.into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            joined_at: "2026-03-28T14:00:00Z".into(),
            updated_at: "2026-03-28T14:05:00Z".into(),
            status: AgentStatus::Active,
            agent_session_id: Some(runtime_session_id.into()),
            last_activity_at: Some("2026-03-28T14:05:00Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        },
    );

    let mut state = SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 0,
        session_id: session_id.into(),
        title: "test session".into(),
        context: "test goal".into(),
        status: SessionStatus::Active,
        created_at: "2026-03-28T14:00:00Z".into(),
        updated_at: "2026-03-28T14:05:00Z".into(),
        agents,
        tasks: BTreeMap::new(),
        leader_id: Some(format!("{runtime}-worker")),
        archived_at: None,
        last_activity_at: Some("2026-03-28T14:05:00Z".into()),
        observe_id: Some(OBSERVE_ID.into()),
        pending_leader_transfer: None,
        metrics: SessionMetrics::default(),
    };
    state.metrics = SessionMetrics::recalculate(&state);
    state
}

pub(super) fn sample_signal_with_idempotency(
    signal_id: &str,
    message: &str,
    idempotency_key: Option<&str>,
) -> Signal {
    Signal {
        signal_id: signal_id.into(),
        version: 1,
        created_at: "2026-03-28T14:03:00Z".into(),
        expires_at: "2026-03-28T14:13:00Z".into(),
        source_agent: "leader-claude".into(),
        command: "inject_context".into(),
        priority: SignalPriority::High,
        payload: SignalPayload {
            message: message.into(),
            action_hint: Some("refresh the cockpit".into()),
            related_files: vec!["src/daemon/snapshot.rs".into()],
            metadata: serde_json::json!({"source": "test"}),
        },
        delivery: DeliveryConfig {
            max_retries: 3,
            retry_count: 0,
            idempotency_key: idempotency_key.map(ToString::to_string),
        },
    }
}

pub(super) fn sample_signal(signal_id: &str, message: &str) -> Signal {
    sample_signal_with_idempotency(signal_id, message, None)
}

pub(super) fn sample_work_item(
    task_id: &str,
    severity: TaskSeverity,
    created_at: &str,
    updated_at: &str,
) -> WorkItem {
    WorkItem {
        task_id: task_id.to_string(),
        title: task_id.to_string(),
        context: None,
        severity,
        status: TaskStatus::Open,
        assigned_to: None,
        queue_policy: TaskQueuePolicy::Locked,
        queued_at: None,
        created_at: created_at.to_string(),
        updated_at: updated_at.to_string(),
        created_by: None,
        notes: vec![],
        suggested_fix: None,
        source: TaskSource::Manual,
        blocked_reason: None,
        completed_at: None,
        checkpoint_summary: None,
    }
}

pub(super) fn observer_state(session_id: &str) -> ObserverState {
    ObserverState {
        schema_version: 1,
        state_version: 0,
        session_id: session_id.into(),
        project_hint: Some("project-alpha".into()),
        cursor: 42,
        last_scan_time: "2026-03-28T14:04:00Z".into(),
        open_issues: vec![OpenIssue {
            issue_id: "issue-1".into(),
            code: IssueCode::AgentStalledProgress,
            fingerprint: "fingerprint".into(),
            first_seen_line: 8,
            last_seen_line: 10,
            occurrence_count: 2,
            severity: IssueSeverity::Critical,
            category: IssueCategory::AgentCoordination,
            summary: "worker stalled".into(),
            fix_safety: FixSafety::TriageRequired,
            evidence_excerpt: Some("No checkpoint for 12 minutes.".into()),
        }],
        resolved_issue_ids: vec!["issue-0".into()],
        issue_attempts: Vec::new(),
        muted_codes: vec![IssueCode::AgentRepeatedError],
        cycle_history: vec![CycleRecord {
            timestamp: "2026-03-28T14:04:00Z".into(),
            from_line: 0,
            to_line: 42,
            new_issues: 1,
            resolved: 0,
        }],
        baseline_issue_ids: Vec::new(),
        active_workers: vec![ActiveWorker {
            issue_id: "issue-1".into(),
            target_file: "src/daemon/snapshot.rs".into(),
            started_at: "2026-03-28T14:04:30Z".into(),
            agent_id: Some("codex-worker".into()),
        }],
        agent_sessions: Vec::new(),
    }
}

pub(super) fn build_project(context_root: PathBuf) -> DiscoveredProject {
    DiscoveredProject {
        project_id: "project-alpha".into(),
        name: "project-alpha".into(),
        project_dir: None,
        repository_root: None,
        checkout_id: "project-alpha".into(),
        checkout_name: "Repository".into(),
        context_root,
        is_worktree: false,
        worktree_name: None,
    }
}

pub(super) fn seed_snapshot_fixture(context_root: &Path, session_id: &str) {
    let state_path = context_root
        .join("orchestration")
        .join("sessions")
        .join(session_id)
        .join("state.json");
    write_json(&state_path, &sample_state(session_id));

    let signal_dir = context_root.join("agents/signals/codex").join(session_id);
    write_signal_file(&signal_dir, &sample_signal("sig-pending", "keep going"))
        .expect("write pending signal");

    let signal = sample_signal("sig-acked", "merged timeline");
    write_signal_file(&signal_dir, &signal).expect("write acked signal");
    acknowledge_signal(
        &signal_dir,
        &SignalAck {
            signal_id: "sig-acked".into(),
            acknowledged_at: "2026-03-28T14:03:10Z".into(),
            result: AckResult::Accepted,
            agent: "codex-worker".into(),
            session_id: session_id.into(),
            details: Some("loaded".into()),
        },
    )
    .expect("ack signal");

    let observer_path = context_root
        .join("agents/observe")
        .join(OBSERVE_ID)
        .join("snapshot.json");
    write_json(&observer_path, &observer_state(session_id));

    let transcript_path = context_root
        .join("agents")
        .join("sessions")
        .join("codex")
        .join("codex-session-1")
        .join("raw.jsonl");
    write_json_line(
        &transcript_path,
        &serde_json::json!({
            "timestamp": "2026-03-28T14:04:45Z",
            "message": {
                "role": "assistant",
                "content": [{
                    "type": "tool_use",
                    "name": "Read",
                    "input": {"path": "src/daemon/snapshot.rs"},
                    "id": "call-read-1"
                }]
            }
        }),
    );
    write_json_line(
        &transcript_path,
        &serde_json::json!({
            "timestamp": "2026-03-28T14:04:46Z",
            "message": {
                "role": "assistant",
                "content": [{
                    "type": "tool_result",
                    "tool_name": "Read",
                    "tool_use_id": "call-read-1",
                    "content": {"line_count": 32},
                    "is_error": false
                }]
            }
        }),
    );
}
