use crate::daemon::agent_tui::AgentTuiStartRequest;
use crate::daemon::http::{
    DaemonHttpState, require_async_db, run_codex_agent_blocking, run_terminal_agent_blocking,
};
use crate::daemon::protocol::{CodexRunMode, CodexRunRequest, ManagedAgentSnapshot};
use crate::errors::{CliError, CliErrorKind};
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole};
use crate::task_board::{
    AgentMode, DispatchAppliedTask, TaskBoardItem, WorkerPromptContext, render_worker_prompt,
};

const DEFAULT_INTERACTIVE_RUNTIME: &str = "codex";

pub(crate) async fn start_worker_for_applied_task(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    // Fail-closed recheck at the shared worker-start seam: this guards the
    // claim+start path used by both the route executor and the recovery loop, so
    // an already-prepared intent cannot start while the kill switch is engaged.
    // Transport-agnostic because it runs before stdio/bridge selection.
    ensure_spawn_kill_switch_clear(state, &applied.board_item_id).await?;
    start_worker_by_mode(state, applied, dispatch_intent_id).await
}

async fn start_worker_by_mode(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    match applied.item.agent_mode {
        AgentMode::Interactive => {
            start_interactive_worker(state, applied, dispatch_intent_id).await
        }
        AgentMode::Headless | AgentMode::Planning | AgentMode::Evaluate => {
            start_codex_worker(state, applied, dispatch_intent_id).await
        }
    }
}

/// Block the worker start when the persisted spawn kill switch is engaged. The
/// caller (route executor or recovery loop) surfaces the error so the intent
/// stays unstarted instead of launching a worker the operator has halted.
async fn ensure_spawn_kill_switch_clear(
    state: &DaemonHttpState,
    board_item_id: &str,
) -> Result<(), CliError> {
    let db = require_async_db(state, "task-board worker start kill-switch check")?;
    let workspace = db.load_policy_workspace().await?;
    if workspace.is_some_and(|workspace| workspace.spawn_kill_switch) {
        warn_kill_switch_at_start(board_item_id);
        return Err(CliErrorKind::invalid_transition(
            "spawn kill switch engaged; worker start refused".to_string(),
        )
        .into());
    }
    Ok(())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing::warn! macro expands into a chain clippy reads as branchy"
)]
fn warn_kill_switch_at_start(board_item_id: &str) {
    tracing::warn!(
        target: "harness::task_board",
        board_item_id = %board_item_id,
        "spawn kill switch engaged at worker start; refusing to launch worker",
    );
}

async fn start_codex_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let session_id = applied.session_id.clone();
    let run_id = codex_worker_id(dispatch_intent_id);
    let request = codex_worker_request(applied, &run_id);
    let _guard = state
        .managed_agent_mutation_locks
        .lock(&session_id, "task-board:codex-worker")
        .await;
    run_codex_agent_blocking(state, "task-board worker start", move |controller| {
        controller
            .start_run_with_id(&session_id, &request, run_id)
            .map(ManagedAgentSnapshot::Codex)
    })
    .await
}

async fn start_interactive_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> Result<ManagedAgentSnapshot, CliError> {
    let session_id = applied.session_id.clone();
    let tui_id = terminal_worker_id(dispatch_intent_id);
    let request = terminal_worker_request(applied, &tui_id);
    let _guard = state
        .managed_agent_mutation_locks
        .lock(&session_id, "task-board:terminal-worker")
        .await;
    run_terminal_agent_blocking(state, "task-board worker start", move |manager| {
        manager
            .start_with_id(&session_id, &request, tui_id)
            .map(ManagedAgentSnapshot::Terminal)
    })
    .await
}

fn codex_worker_request(applied: &DispatchAppliedTask, managed_run_id: &str) -> CodexRunRequest {
    let mode = match applied.item.agent_mode {
        AgentMode::Evaluate => CodexRunMode::Report,
        AgentMode::Headless | AgentMode::Planning | AgentMode::Interactive => {
            CodexRunMode::WorkspaceWrite
        }
    };
    CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt: worker_prompt(applied, managed_run_id),
        mode,
        role: SessionRole::Worker,
        fallback_role: Some(SessionRole::Observer),
        capabilities: worker_capabilities(&applied.item),
        name: Some(worker_name(&applied.item)),
        persona: None,
        resume_thread_id: None,
        task_id: Some(applied.work_item_id.clone()),
        board_item_id: Some(applied.board_item_id.clone()),
        workflow_execution_id: applied.item.workflow.execution_id.clone(),
        model: None,
        effort: None,
        allow_custom_model: false,
    }
}

fn terminal_worker_request(
    applied: &DispatchAppliedTask,
    managed_run_id: &str,
) -> AgentTuiStartRequest {
    AgentTuiStartRequest {
        runtime: DEFAULT_INTERACTIVE_RUNTIME.to_string(),
        role: SessionRole::Worker,
        fallback_role: Some(SessionRole::Observer),
        capabilities: worker_capabilities(&applied.item),
        name: Some(worker_name(&applied.item)),
        prompt: Some(worker_prompt(applied, managed_run_id)),
        project_dir: None,
        argv: Vec::new(),
        rows: 24,
        cols: 80,
        persona: None,
        task_id: Some(applied.work_item_id.clone()),
        board_item_id: Some(applied.board_item_id.clone()),
        workflow_execution_id: applied.item.workflow.execution_id.clone(),
        model: None,
        effort: None,
        allow_custom_model: false,
    }
}

fn worker_name(item: &TaskBoardItem) -> String {
    format!("Task Board: {}", item.title)
}

fn codex_worker_id(dispatch_intent_id: &str) -> String {
    format!("codex-{dispatch_intent_id}")
}

fn terminal_worker_id(dispatch_intent_id: &str) -> String {
    format!("agent-tui-{dispatch_intent_id}")
}

fn worker_capabilities(item: &TaskBoardItem) -> Vec<String> {
    let mut capabilities = vec![
        "task-board".to_string(),
        format!("task-board:item:{}", item.id),
    ];
    capabilities.extend(item.tags.iter().map(|tag| format!("task-board:tag:{tag}")));
    capabilities
}

fn worker_prompt(applied: &DispatchAppliedTask, managed_run_id: &str) -> String {
    render_worker_prompt(
        &applied.item,
        &WorkerPromptContext {
            board_item_id: &applied.board_item_id,
            work_item_id: &applied.work_item_id,
            worktree: applied.item.workflow.worktree.as_deref(),
            session_id: Some(&applied.session_id),
            managed_run_id: Some(managed_run_id),
            status: applied.item.status,
        },
    )
}

pub(crate) fn rendered_worker_prompt(
    applied: &DispatchAppliedTask,
    dispatch_intent_id: &str,
) -> String {
    let managed_run_id = if applied.item.agent_mode == AgentMode::Interactive {
        terminal_worker_id(dispatch_intent_id)
    } else {
        codex_worker_id(dispatch_intent_id)
    };
    worker_prompt(applied, &managed_run_id)
}

#[cfg(test)]
mod tests {
    use std::env::temp_dir;
    use std::sync::{Arc, Mutex, OnceLock};
    use std::time::Duration;

    use serde_json::json;
    use tokio::sync::broadcast;
    use tokio::time::timeout;
    use uuid::Uuid;

    use crate::daemon::agent_acp::AcpAgentManagerHandle;
    use crate::daemon::agent_tui::AgentTuiManagerHandle;
    use crate::daemon::codex_controller::CodexControllerHandle;
    use crate::daemon::db::DaemonDb;
    use crate::daemon::http::{
        AsyncDaemonDbSlot, DaemonHttpState, ManagedAgentMutationLocks, connect_async_db_for_tests,
    };
    use crate::daemon::state::{DaemonManifest, HostBridgeManifest};
    use crate::daemon::websocket::ReplayBuffer;
    use crate::task_board::dispatch::DispatchLifecycle;
    use crate::task_board::{
        AgentMode, DispatchAppliedTask, TaskBoardItem, TaskBoardPriority, TaskBoardStatus,
        TaskBoardWorkflowState,
    };
    use crate::workspace::utc_now;

    use super::{
        codex_worker_id, codex_worker_request, start_interactive_worker, terminal_worker_id,
        terminal_worker_request,
    };

    #[test]
    fn codex_worker_request_carries_task_board_identity() {
        let applied = applied_task(AgentMode::Headless);

        let request = codex_worker_request(&applied, "codex-dispatch-intent-1");

        assert_eq!(request.task_id.as_deref(), Some("task-1"));
        assert_eq!(request.board_item_id.as_deref(), Some("board-1"));
        assert_eq!(request.workflow_execution_id.as_deref(), Some("workflow-1"));
        assert!(
            request
                .capabilities
                .contains(&"task-board:item:board-1".to_string())
        );
        assert!(request.prompt.contains("Session task: task-1"));
        assert!(request.prompt.contains("Session id:\nsession-1"));
        assert!(request.prompt.contains("Tags:\nbackend"));
        assert!(request.prompt.contains("Worktree:\n/tmp/task-worktree"));
        assert!(request.prompt.contains("External refs:\ngithub:123"));
        assert!(
            request
                .prompt
                .contains("Managed run id:\ncodex-dispatch-intent-1")
        );
        assert!(
            request
                .prompt
                .contains("harness session task list session-1 --json")
        );
        assert!(
            request
                .prompt
                .contains("harness session task submit-for-review session-1 task-1")
        );
        assert!(request.prompt.contains("authoritative safety net"));
    }

    #[test]
    fn interactive_worker_request_uses_terminal_runtime() {
        let applied = applied_task(AgentMode::Interactive);

        let request = terminal_worker_request(&applied, "agent-tui-dispatch-intent-1");

        assert_eq!(request.runtime, "codex");
        assert_eq!(request.task_id.as_deref(), Some("task-1"));
        assert_eq!(request.board_item_id.as_deref(), Some("board-1"));
        assert_eq!(request.rows, 24);
        assert_eq!(request.cols, 80);
    }

    #[test]
    fn worker_identity_is_stable_for_reclaimed_dispatch_claims() {
        assert_eq!(
            codex_worker_id("dispatch-intent-1"),
            codex_worker_id("dispatch-intent-1")
        );
        assert_eq!(
            terminal_worker_id("dispatch-intent-1"),
            terminal_worker_id("dispatch-intent-1")
        );
        assert_ne!(
            codex_worker_id("dispatch-intent-1"),
            codex_worker_id("dispatch-intent-2")
        );
    }

    #[tokio::test]
    async fn start_interactive_worker_waits_for_terminal_lane_guard() {
        let state = test_http_state();
        let applied = applied_task(AgentMode::Interactive);
        let outer_guard = state
            .managed_agent_mutation_locks
            .lock(&applied.session_id, "task-board:terminal-worker")
            .await;

        let future = start_interactive_worker(&state, &applied, "dispatch-intent-test");
        tokio::pin!(future);

        assert!(
            timeout(Duration::from_millis(50), future.as_mut())
                .await
                .is_err(),
            "interactive worker spawn must wait for the terminal-worker lane",
        );

        drop(outer_guard);

        let result = timeout(Duration::from_secs(2), future)
            .await
            .expect("interactive worker spawn resumes once the lane is free");
        // Spawning the real TUI fails in the test environment because no
        // session is registered; the lock contract is what we care about.
        assert!(
            result.is_err(),
            "test daemon has no session for the TUI spawn, expected error",
        );
    }

    fn test_http_state() -> DaemonHttpState {
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
            remote_pairing_status_limiter:
                crate::daemon::http::default_remote_pairing_status_limiter(),
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

    fn applied_task(mode: AgentMode) -> DispatchAppliedTask {
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
        }
    }
}
