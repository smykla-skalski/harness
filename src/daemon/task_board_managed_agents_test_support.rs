use std::env::temp_dir;
use std::sync::{Arc, Mutex, OnceLock};

use serde_json::json;
use tokio::sync::broadcast;
use uuid::Uuid;

use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::agent_tui::{
    AgentTuiManagerHandle, AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus, TerminalScreenSnapshot,
};
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::DaemonDb;
use crate::daemon::http::{
    AsyncDaemonDbSlot, DaemonHttpState, ManagedAgentMutationLocks, connect_async_db_for_tests,
};
use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus};
use crate::daemon::state::{DaemonManifest, HostBridgeManifest};
use crate::daemon::websocket::ReplayBuffer;
use crate::task_board::dispatch::DispatchLifecycle;
use crate::task_board::{
    AgentMode, DispatchAppliedTask, TaskBoardItem, TaskBoardPriority, TaskBoardStatus,
    TaskBoardWorkflowState,
};
use crate::workspace::utc_now;

pub(super) fn test_http_state() -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db_slot = Arc::new(OnceLock::new());
    let async_db = Arc::new(OnceLock::new());
    let db_path = temp_dir().join(format!("harness-tb-managed-{}.db", Uuid::new_v4()));
    db_slot
        .set(Arc::new(Mutex::new(
            DaemonDb::open(&db_path).expect("open file db"),
        )))
        .expect("install db");
    async_db
        .set(connect_async_db_for_tests(&db_path))
        .expect("install async db");
    let manifest: DaemonManifest = serde_json::from_value(json!({
        "version": "20.6.0",
        "pid": 1,
        "endpoint": "http://127.0.0.1:0",
        "started_at": "2026-05-15T00:00:00Z",
        "token_path": "/tmp/token",
        "sandboxed": false,
        "host_bridge": HostBridgeManifest::default(),
        "revision": 0,
        "updated_at": "",
    }))
    .expect("deserialize daemon manifest");
    DaemonHttpState {
        token: "token".into(),
        auth_mode: crate::daemon::http::DaemonHttpAuthMode::Local,
        remote_domain: None,
        remote_request_limits: None,
        remote_pairing_limiter: crate::daemon::http::default_remote_pairing_limiter(),
        remote_pairing_status_limiter: crate::daemon::http::default_remote_pairing_status_limiter(),
        sender: sender.clone(),
        prepared_sender: broadcast::channel(8).0,
        manifest,
        daemon_epoch: "epoch".into(),
        replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
        db: db_slot.clone(),
        async_db: AsyncDaemonDbSlot::from_inner(async_db.clone()),
        db_path: Some(db_path),
        codex_controller: CodexControllerHandle::new_with_async_db(
            sender.clone(),
            db_slot.clone(),
            async_db.clone(),
            false,
        ),
        acp_agent_manager: AcpAgentManagerHandle::new_with_async_db(
            sender.clone(),
            db_slot.clone(),
            async_db.clone(),
        ),
        agent_tui_manager: AgentTuiManagerHandle::new_with_async_db(
            sender.clone(),
            db_slot,
            async_db,
            false,
        ),
        managed_agent_mutation_locks: ManagedAgentMutationLocks::default(),
        recovery_snapshot: Default::default(),
    }
}

pub(super) fn applied_task(mode: AgentMode) -> DispatchAppliedTask {
    let mut item = TaskBoardItem::new(
        "board-1".into(),
        "Ship managed worker launch".into(),
        "Start a real worker.".into(),
        utc_now(),
    );
    item.agent_mode = mode;
    item.status = TaskBoardStatus::InProgress;
    item.priority = TaskBoardPriority::High;
    item.tags = vec!["backend".into()];
    item.external_refs = vec![crate::task_board::ExternalRef {
        provider: crate::task_board::ExternalRefProvider::GitHub,
        external_id: "123".into(),
        url: Some("https://github.example/issues/123".into()),
        sync_state: None,
    }];
    item.workflow = TaskBoardWorkflowState {
        execution_id: Some("workflow-1".into()),
        worktree: Some("/tmp/task-worktree".into()),
        ..TaskBoardWorkflowState::default()
    };
    DispatchAppliedTask {
        board_item_id: item.id.clone(),
        session_id: "session-1".into(),
        work_item_id: "task-1".into(),
        lifecycle: DispatchLifecycle::planned(
            &crate::task_board::WorkerIntent { mode },
            &crate::task_board::ReviewerIntent {
                phase: crate::task_board::FollowUpPhase::AfterWorkerReview,
                suggested_persona: "code-reviewer".into(),
                required_consensus: 2,
            },
            &crate::task_board::EvaluatorIntent {
                phase: crate::task_board::FollowUpPhase::AfterWorkerReview,
                mode: AgentMode::Evaluate,
            },
        ),
        item,
        read_only_workflow: None,
    }
}

pub(super) fn terminal_snapshot(status: AgentTuiStatus, session_id: &str) -> AgentTuiSnapshot {
    AgentTuiSnapshot {
        tui_id: "agent-tui-dispatch-intent-existing".into(),
        session_id: session_id.into(),
        agent_id: "worker-terminal".into(),
        runtime: "codex".into(),
        status,
        argv: Vec::new(),
        project_dir: "/tmp/project".into(),
        size: AgentTuiSize { rows: 24, cols: 80 },
        screen: TerminalScreenSnapshot {
            rows: 24,
            cols: 80,
            cursor_row: 0,
            cursor_col: 0,
            text: String::new(),
        },
        transcript_path: "/tmp/transcript".into(),
        exit_code: None,
        signal: None,
        error: None,
        created_at: "2026-07-17T00:00:00Z".into(),
        updated_at: "2026-07-17T00:00:01Z".into(),
    }
}

pub(super) fn codex_snapshot(status: CodexRunStatus, session_id: &str) -> CodexRunSnapshot {
    CodexRunSnapshot {
        run_id: "codex-dispatch-intent-existing".into(),
        session_id: session_id.into(),
        task_id: Some("task-1".into()),
        board_item_id: Some("board-1".into()),
        workflow_execution_id: Some("workflow-1".into()),
        session_agent_id: Some("worker-codex".into()),
        display_name: Some("Codex".into()),
        project_dir: "/tmp/project".into(),
        thread_id: Some("thread-1".into()),
        turn_id: None,
        mode: CodexRunMode::WorkspaceWrite,
        status,
        prompt: "work".into(),
        latest_summary: None,
        final_message: None,
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: "2026-07-17T00:00:00Z".into(),
        updated_at: "2026-07-17T00:00:01Z".into(),
        model: None,
        effort: None,
    }
}
