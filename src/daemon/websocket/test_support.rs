use std::collections::BTreeMap;
use std::env::temp_dir;
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::json;
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::agents::runtime::RuntimeCapabilities;
use crate::agents::runtime::event::{ConversationEvent, ConversationEventKind};
use crate::daemon::agent_tui::{
    AgentTuiManagerHandle, AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
};
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::http::DaemonHttpState;
use crate::daemon::index::DiscoveredProject;
use crate::daemon::state::{DaemonManifest, HostBridgeManifest};
use crate::session::types::{
    AgentRegistration, AgentStatus, SessionMetrics, SessionRole, SessionState, SessionStatus,
};

use super::ReplayBuffer;

pub(super) fn test_ws_state() -> DaemonHttpState {
    build_test_http_state("20.6.0", "2026-04-13T00:00:00Z", false)
}

pub(super) fn test_http_state() -> DaemonHttpState {
    build_test_http_state("18.2.3", "2026-04-04T00:00:00Z", false)
}

pub(super) fn test_http_state_with_db() -> DaemonHttpState {
    build_test_http_state("18.2.3", "2026-04-04T00:00:00Z", true)
}

pub(super) fn seed_sample_session(state: &DaemonHttpState) {
    let db = state.db.get().expect("db slot").clone();
    let db = db.lock().expect("db lock");
    persist_sample_session(&db);
}

pub(super) fn seed_sample_agent_tui(state: &DaemonHttpState, tui_id: &str, updated_at: &str) {
    let db = state.db.get().expect("db slot").clone();
    let db = db.lock().expect("db lock");
    persist_sample_session(&db);
    db.save_agent_tui(&sample_agent_tui(tui_id, updated_at))
        .expect("save agent tui");
}

pub(super) fn seed_sample_timeline(state: &DaemonHttpState) {
    let db = state.db.get().expect("db slot").clone();
    let db = db.lock().expect("db lock");
    persist_sample_session(&db);
    db.sync_conversation_events(
        "sess-test-1",
        "codex-worker",
        "codex",
        &[sample_tool_result_event()],
    )
    .expect("sync conversation events");
}

pub(super) async fn test_http_state_with_async_db_timeline() -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db = Arc::new(OnceLock::new());
    let async_db = Arc::new(OnceLock::new());
    let db_path = temp_dir().join(format!("harness-ws-test-async-{}.db", Uuid::new_v4()));
    let sync_db = DaemonDb::open(&db_path).expect("open file db");
    persist_sample_session(&sync_db);
    sync_db
        .sync_conversation_events(
            "sess-test-1",
            "codex-worker",
            "codex",
            &[sample_tool_result_event()],
        )
        .expect("sync conversation events");
    drop(sync_db);

    assert!(
        async_db
            .set(Arc::new(
                AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db"),
            ))
            .is_ok(),
        "install async db"
    );

    DaemonHttpState {
        token: "token".into(),
        sender: sender.clone(),
        manifest: sample_manifest("18.2.3", "2026-04-04T00:00:00Z"),
        daemon_epoch: "epoch".into(),
        replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
        db: db.clone(),
        async_db: crate::daemon::http::AsyncDaemonDbSlot::from_inner(async_db.clone()),
        db_path: Some(db_path),
        codex_controller: CodexControllerHandle::new_with_async_db(
            sender.clone(),
            db.clone(),
            async_db.clone(),
            false,
        ),
        agent_tui_manager: AgentTuiManagerHandle::new_with_async_db(sender, db, async_db, false),
    }
}

fn build_test_http_state(version: &str, started_at: &str, install_db: bool) -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db = Arc::new(OnceLock::new());
    let db_path =
        install_db.then(|| temp_dir().join(format!("harness-ws-test-{}.db", Uuid::new_v4())));
    if install_db {
        db.set(Arc::new(Mutex::new(
            DaemonDb::open(db_path.as_ref().expect("db path")).expect("open file db"),
        )))
        .expect("install db");
    }

    DaemonHttpState {
        token: "token".into(),
        sender: sender.clone(),
        manifest: sample_manifest(version, started_at),
        daemon_epoch: "epoch".into(),
        replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
        db: db.clone(),
        async_db: crate::daemon::http::AsyncDaemonDbSlot::empty(),
        db_path,
        codex_controller: CodexControllerHandle::new(sender.clone(), db.clone(), false),
        agent_tui_manager: AgentTuiManagerHandle::new(sender, db, false),
    }
}

fn sample_manifest(version: &str, started_at: &str) -> DaemonManifest {
    serde_json::from_value(json!({
        "version": version,
        "pid": 1,
        "endpoint": "http://127.0.0.1:0",
        "started_at": started_at,
        "token_path": "/tmp/token",
        "sandboxed": false,
        "host_bridge": HostBridgeManifest::default(),
        "revision": 0,
        "updated_at": "",
    }))
    .expect("deserialize daemon manifest")
}

fn persist_sample_session(db: &DaemonDb) {
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    db.save_session_state(&project.project_id, &sample_session_state())
        .expect("save session state");
}

fn sample_agent_tui(tui_id: &str, updated_at: &str) -> AgentTuiSnapshot {
    AgentTuiSnapshot {
        tui_id: tui_id.into(),
        session_id: "sess-test-1".into(),
        agent_id: "codex-worker".into(),
        runtime: "codex".into(),
        status: AgentTuiStatus::Running,
        argv: vec!["codex".into()],
        project_dir: "/tmp/harness".into(),
        size: AgentTuiSize {
            rows: 30,
            cols: 120,
        },
        screen: TerminalScreenSnapshot {
            rows: 30,
            cols: 120,
            cursor_row: 1,
            cursor_col: 5,
            text: "ready".into(),
        },
        transcript_path: "/tmp/harness/agent-tui.log".into(),
        exit_code: None,
        signal: None,
        error: None,
        created_at: "2026-04-13T19:00:00Z".into(),
        updated_at: updated_at.into(),
    }
}

fn sample_project() -> DiscoveredProject {
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

fn sample_session_state() -> SessionState {
    let mut agents = BTreeMap::new();
    agents.insert(
        "codex-worker".into(),
        AgentRegistration {
            agent_id: "codex-worker".into(),
            name: "Codex Worker".into(),
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec!["general".into()],
            joined_at: "2026-04-13T19:00:00Z".into(),
            updated_at: "2026-04-13T19:00:00Z".into(),
            status: AgentStatus::Active,
            agent_session_id: None,
            last_activity_at: Some("2026-04-13T19:00:00Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        },
    );

    SessionState {
        schema_version: 3,
        state_version: 1,
        session_id: "sess-test-1".into(),
        title: "sess-test-1".into(),
        context: "agent tui websocket fixture".into(),
        status: SessionStatus::Active,
        created_at: "2026-04-13T19:00:00Z".into(),
        updated_at: "2026-04-13T19:00:00Z".into(),
        agents,
        tasks: BTreeMap::new(),
        leader_id: None,
        archived_at: None,
        last_activity_at: Some("2026-04-13T19:00:00Z".into()),
        observe_id: None,
        pending_leader_transfer: None,
        metrics: SessionMetrics::default(),
    }
}

fn sample_tool_result_event() -> ConversationEvent {
    ConversationEvent {
        timestamp: Some("2026-04-13T19:02:00Z".into()),
        sequence: 1,
        kind: ConversationEventKind::ToolResult {
            tool_name: "Bash".into(),
            invocation_id: Some("call-bash-1".into()),
            output: json!({
                "stdout": "x".repeat(8_192),
                "exit_code": 0,
            }),
            is_error: false,
            duration_ms: Some(125),
        },
        agent: "codex-worker".into(),
        session_id: "sess-test-1".into(),
    }
}
