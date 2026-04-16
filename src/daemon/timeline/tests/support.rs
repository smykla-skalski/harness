use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use fs_err as fs;

use crate::agents::runtime::RuntimeCapabilities;
use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::agents::runtime::signal::{
    AckResult, DeliveryConfig, Signal, SignalAck, SignalPayload, SignalPriority,
    acknowledge_signal, write_signal_file,
};
use crate::observe::types::{
    ActiveWorker, CycleRecord, FixSafety, IssueCategory, IssueCode, IssueSeverity, ObserverState,
    OpenIssue,
};
use crate::session::types::{
    AgentRegistration, AgentStatus, CURRENT_VERSION, SessionLogEntry, SessionMetrics, SessionRole,
    SessionState, SessionStatus, SessionTransition, TaskCheckpoint, TaskQueuePolicy, TaskSeverity,
    TaskStatus, WorkItem,
};

const OBSERVE_ID: &str = "observe-sess-merge";
const PROJECT_ROOT: &str = "harness/projects/project-alpha";
const RUNTIME_SESSION_ID: &str = "codex-session-1";
const SIGNAL_ID: &str = "sig-acked";

pub(super) struct TimelineFixture {
    pub(super) log_entry: SessionLogEntry,
    pub(super) signal_sent: SessionLogEntry,
    pub(super) checkpoint: TaskCheckpoint,
    pub(super) db_events: Vec<ConversationEvent>,
}

pub(super) fn context_root(base: &Path) -> PathBuf {
    base.join(PROJECT_ROOT)
}

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

pub(super) fn write_standard_timeline_fixture(
    context_root: &Path,
    session_id: &str,
) -> TimelineFixture {
    let state_path = context_root
        .join("orchestration")
        .join("sessions")
        .join(session_id)
        .join("state.json");
    write_json(&state_path, &sample_state(session_id));

    let log_entry = sample_log_entry(session_id);
    let signal_sent = sample_signal_sent_entry(session_id);
    let log_path = context_root
        .join("orchestration")
        .join("sessions")
        .join(session_id)
        .join("log.jsonl");
    write_json_line(&log_path, &log_entry);
    write_json_line(&log_path, &signal_sent);

    let checkpoint = sample_checkpoint();
    let checkpoint_path = context_root
        .join("orchestration")
        .join("sessions")
        .join(session_id)
        .join("tasks")
        .join("task-1")
        .join("checkpoints.jsonl");
    write_json_line(&checkpoint_path, &checkpoint);

    write_signal_fixture(context_root, session_id);
    write_json(
        &context_root
            .join("agents/observe")
            .join(OBSERVE_ID)
            .join("snapshot.json"),
        &observer_state(session_id),
    );

    let db_events = standard_conversation_events(session_id);
    write_standard_transcript(context_root);

    TimelineFixture {
        log_entry,
        signal_sent,
        checkpoint,
        db_events,
    }
}

pub(super) fn write_copilot_ledger_fixture(context_root: &Path, session_id: &str) {
    let state_path = context_root
        .join("orchestration")
        .join("sessions")
        .join(session_id)
        .join("state.json");
    write_json(
        &state_path,
        &sample_state_for_runtime(session_id, "copilot", "copilot-session-1"),
    );

    let ledger_path = context_root.join("agents/ledger/events.jsonl");
    write_json_line(
        &ledger_path,
        &serde_json::json!({
            "sequence": 1,
            "recorded_at": "2026-03-28T14:04:45Z",
            "agent": "copilot",
            "session_id": "copilot-session-1",
            "skill": "suite",
            "event": "before_tool_use",
            "hook": "tool-guard",
            "decision": "allow",
            "payload": {
                "timestamp": "2026-03-28T14:04:45Z",
                "message": {
                    "role": "assistant",
                    "content": [{
                        "type": "tool_use",
                        "name": "Read",
                        "input": {"path": "README.md"},
                        "id": "call-read-1",
                    }]
                }
            }
        }),
    );
    write_json_line(
        &ledger_path,
        &serde_json::json!({
            "sequence": 2,
            "recorded_at": "2026-03-28T14:04:46Z",
            "agent": "copilot",
            "session_id": "copilot-session-1",
            "skill": "suite",
            "event": "after_tool_use",
            "hook": "tool-result",
            "decision": "allow",
            "payload": {
                "timestamp": "2026-03-28T14:04:46Z",
                "message": {
                    "role": "assistant",
                    "content": [{
                        "type": "tool_result",
                        "tool_name": "Read",
                        "tool_use_id": "call-read-1",
                        "content": {"line_count": 12},
                        "is_error": false,
                    }]
                }
            }
        }),
    );
}

fn sample_state(session_id: &str) -> SessionState {
    sample_state_for_runtime(session_id, "codex", RUNTIME_SESSION_ID)
}

fn sample_state_for_runtime(
    session_id: &str,
    runtime: &str,
    runtime_session_id: &str,
) -> SessionState {
    let worker_id = format!("{runtime}-worker");
    let mut agents = BTreeMap::new();
    agents.insert(
        worker_id.clone(),
        AgentRegistration {
            agent_id: worker_id.clone(),
            name: format!("{} Worker", runtime.to_uppercase()),
            runtime: runtime.into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            joined_at: "2026-03-28T14:00:00Z".into(),
            updated_at: "2026-03-28T14:05:00Z".into(),
            status: AgentStatus::Active,
            agent_session_id: Some(runtime_session_id.into()),
            last_activity_at: Some("2026-03-28T14:05:00Z".into()),
            current_task_id: Some("task-1".into()),
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        },
    );

    let mut tasks = BTreeMap::new();
    tasks.insert(
        "task-1".into(),
        WorkItem {
            task_id: "task-1".into(),
            title: "finish cockpit".into(),
            context: Some("merge timeline entries".into()),
            severity: TaskSeverity::High,
            status: TaskStatus::InProgress,
            assigned_to: Some(worker_id.clone()),
            queue_policy: TaskQueuePolicy::Locked,
            queued_at: None,
            created_at: "2026-03-28T14:00:00Z".into(),
            updated_at: "2026-03-28T14:05:00Z".into(),
            created_by: Some("leader-claude".into()),
            notes: Vec::new(),
            suggested_fix: None,
            source: crate::session::types::TaskSource::Manual,
            observe_issue_id: None,
            blocked_reason: None,
            completed_at: None,
            checkpoint_summary: None,
        },
    );

    SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 0,
        session_id: session_id.into(),
        title: "test session".into(),
        context: "test goal".into(),
        status: SessionStatus::Active,
        policy: Default::default(),
        created_at: "2026-03-28T14:00:00Z".into(),
        updated_at: "2026-03-28T14:05:00Z".into(),
        agents,
        tasks,
        leader_id: Some(worker_id),
        archived_at: None,
        last_activity_at: Some("2026-03-28T14:05:00Z".into()),
        observe_id: Some(OBSERVE_ID.into()),
        pending_leader_transfer: None,
        metrics: SessionMetrics::default(),
    }
}

fn sample_log_entry(session_id: &str) -> SessionLogEntry {
    SessionLogEntry {
        sequence: 1,
        recorded_at: "2026-03-28T14:01:00Z".into(),
        session_id: session_id.into(),
        transition: SessionTransition::TaskCreated {
            task_id: "task-1".into(),
            title: "finish cockpit".into(),
            severity: TaskSeverity::High,
        },
        actor_id: Some("leader-claude".into()),
        reason: None,
    }
}

fn sample_signal_sent_entry(session_id: &str) -> SessionLogEntry {
    SessionLogEntry {
        sequence: 2,
        recorded_at: "2026-03-28T14:03:00Z".into(),
        session_id: session_id.into(),
        transition: SessionTransition::SignalSent {
            signal_id: SIGNAL_ID.into(),
            agent_id: "codex-worker".into(),
            command: "inject_context".into(),
        },
        actor_id: Some("leader-claude".into()),
        reason: None,
    }
}

fn sample_checkpoint() -> TaskCheckpoint {
    TaskCheckpoint {
        checkpoint_id: "task-1-cp-1".into(),
        task_id: "task-1".into(),
        recorded_at: "2026-03-28T14:06:00Z".into(),
        actor_id: Some("worker-codex".into()),
        summary: "timeline rows are live-backed".into(),
        progress: 70,
    }
}

fn write_signal_fixture(context_root: &Path, session_id: &str) {
    let signal_dir = context_root.join("agents/signals/codex").join(session_id);
    let signal = sample_signal(SIGNAL_ID, "merged timeline");
    write_signal_file(&signal_dir, &signal).expect("write acked signal");
    acknowledge_signal(
        &signal_dir,
        &SignalAck {
            signal_id: SIGNAL_ID.into(),
            acknowledged_at: "2026-03-28T14:03:10Z".into(),
            result: AckResult::Accepted,
            agent: "codex".into(),
            session_id: session_id.into(),
            details: Some("loaded".into()),
        },
    )
    .expect("ack signal");
}

fn standard_conversation_events(session_id: &str) -> Vec<ConversationEvent> {
    vec![
        ConversationEvent {
            timestamp: Some("2026-03-28T14:05:30Z".into()),
            sequence: 1,
            kind: ConversationEventKind::ToolInvocation {
                tool_name: "Read".into(),
                category: "fs".into(),
                input: serde_json::json!({"path": "src/daemon/timeline.rs"}),
                invocation_id: Some("call-read-1".into()),
            },
            agent: "codex-worker".into(),
            session_id: session_id.into(),
        },
        ConversationEvent {
            timestamp: Some("2026-03-28T14:05:45Z".into()),
            sequence: 2,
            kind: ConversationEventKind::ToolResult {
                tool_name: "Read".into(),
                invocation_id: Some("call-read-1".into()),
                output: serde_json::json!({"line_count": 48}),
                is_error: false,
                duration_ms: None,
            },
            agent: "codex-worker".into(),
            session_id: session_id.into(),
        },
    ]
}

fn write_standard_transcript(context_root: &Path) {
    let transcript_path = context_root
        .join("agents")
        .join("sessions")
        .join("codex")
        .join(RUNTIME_SESSION_ID)
        .join("raw.jsonl");
    write_json_line(
        &transcript_path,
        &serde_json::json!({
            "timestamp": "2026-03-28T14:05:30Z",
            "message": {
                "role": "assistant",
                "content": [{
                    "type": "tool_use",
                    "name": "Read",
                    "input": {"path": "src/daemon/timeline.rs"},
                    "id": "call-read-1"
                }]
            }
        }),
    );
    write_json_line(
        &transcript_path,
        &serde_json::json!({
            "timestamp": "2026-03-28T14:05:45Z",
            "message": {
                "role": "assistant",
                "content": [{
                    "type": "tool_result",
                    "tool_name": "Read",
                    "tool_use_id": "call-read-1",
                    "content": {"line_count": 48},
                    "is_error": false
                }]
            }
        }),
    );
}

fn sample_signal(signal_id: &str, message: &str) -> Signal {
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
            related_files: vec!["src/daemon/timeline.rs".into()],
            metadata: serde_json::json!({"source": "test"}),
        },
        delivery: DeliveryConfig {
            max_retries: 3,
            retry_count: 0,
            idempotency_key: None,
        },
    }
}

fn observer_state(session_id: &str) -> ObserverState {
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
            target_file: "src/daemon/timeline.rs".into(),
            started_at: "2026-03-28T14:04:30Z".into(),
            agent_id: Some("codex-worker".into()),
        }],
        agent_sessions: Vec::new(),
    }
}
