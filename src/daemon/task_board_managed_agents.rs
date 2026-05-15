use crate::daemon::agent_tui::AgentTuiStartRequest;
use crate::daemon::http::DaemonHttpState;
use crate::daemon::protocol::{
    CodexRunMode, CodexRunRequest, ManagedAgentSnapshot, TaskBoardOrchestratorRunOnceResponse,
};
use crate::errors::CliError;
use crate::session::types::{CONTROL_PLANE_ACTOR_ID, SessionRole};
use crate::task_board::{AgentMode, DispatchAppliedTask, TaskBoardItem};

const DEFAULT_INTERACTIVE_RUNTIME: &str = "codex";

pub(crate) async fn start_workers_for_applied_dispatch(
    state: &DaemonHttpState,
    applied: &[DispatchAppliedTask],
) -> Result<Vec<ManagedAgentSnapshot>, CliError> {
    let mut snapshots = Vec::new();
    for applied_task in applied {
        snapshots.push(start_worker_for_applied_task(state, applied_task).await?);
    }
    Ok(snapshots)
}

pub(crate) async fn start_workers_for_run_once_status(
    state: &DaemonHttpState,
    status: &TaskBoardOrchestratorRunOnceResponse,
) -> Result<Vec<ManagedAgentSnapshot>, CliError> {
    let applied = status
        .last_run
        .as_ref()
        .and_then(|run| run.dispatch.as_ref())
        .map(|dispatch| dispatch.applied.as_slice())
        .unwrap_or_default();
    start_workers_for_applied_dispatch(state, applied).await
}

async fn start_worker_for_applied_task(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
) -> Result<ManagedAgentSnapshot, CliError> {
    match applied.item.agent_mode {
        AgentMode::Interactive => start_interactive_worker(state, applied).await,
        AgentMode::Headless | AgentMode::Planning | AgentMode::Evaluate => {
            start_codex_worker(state, applied).await
        }
    }
}

async fn start_codex_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
) -> Result<ManagedAgentSnapshot, CliError> {
    let request = codex_worker_request(applied);
    let _guard = state
        .managed_agent_mutation_locks
        .lock(&applied.session_id, "task-board:codex-worker")
        .await;
    state
        .codex_controller
        .start_run(&applied.session_id, &request)
        .map(ManagedAgentSnapshot::Codex)
}

async fn start_interactive_worker(
    state: &DaemonHttpState,
    applied: &DispatchAppliedTask,
) -> Result<ManagedAgentSnapshot, CliError> {
    let _guard = state
        .managed_agent_mutation_locks
        .lock(&applied.session_id, "task-board:terminal-worker")
        .await;
    state
        .agent_tui_manager
        .start(&applied.session_id, &terminal_worker_request(applied))
        .map(ManagedAgentSnapshot::Terminal)
}

fn codex_worker_request(applied: &DispatchAppliedTask) -> CodexRunRequest {
    let mode = match applied.item.agent_mode {
        AgentMode::Evaluate => CodexRunMode::Report,
        AgentMode::Headless | AgentMode::Planning | AgentMode::Interactive => {
            CodexRunMode::WorkspaceWrite
        }
    };
    CodexRunRequest {
        actor: Some(CONTROL_PLANE_ACTOR_ID.to_string()),
        prompt: worker_prompt(applied),
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

fn terminal_worker_request(applied: &DispatchAppliedTask) -> AgentTuiStartRequest {
    AgentTuiStartRequest {
        runtime: DEFAULT_INTERACTIVE_RUNTIME.to_string(),
        role: SessionRole::Worker,
        fallback_role: Some(SessionRole::Observer),
        capabilities: worker_capabilities(&applied.item),
        name: Some(worker_name(&applied.item)),
        prompt: Some(worker_prompt(applied)),
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

fn worker_capabilities(item: &TaskBoardItem) -> Vec<String> {
    let mut capabilities = vec![
        "task-board".to_string(),
        format!("task-board:item:{}", item.id),
    ];
    capabilities.extend(item.tags.iter().map(|tag| format!("task-board:tag:{tag}")));
    capabilities
}

fn worker_prompt(applied: &DispatchAppliedTask) -> String {
    let item = &applied.item;
    let mut prompt = format!(
        "Work on task-board item '{}'.\n\nBoard item: {}\nSession task: {}\nPriority: {:?}\nStatus: {:?}",
        item.title, applied.board_item_id, applied.work_item_id, item.priority, item.status
    );
    push_optional_section(&mut prompt, "Project", item.project_id.as_deref());
    push_optional_section(
        &mut prompt,
        "Planning summary",
        item.planning.summary.as_deref(),
    );
    push_optional_section(&mut prompt, "Task body", non_empty(item.body.as_str()));
    prompt.push_str(
        "\n\nFollow the session task lifecycle: implement the requested work, keep changes scoped, run the smallest relevant validation, and submit the task for review when ready.",
    );
    prompt
}

fn push_optional_section(prompt: &mut String, title: &str, value: Option<&str>) {
    let Some(value) = value else {
        return;
    };
    prompt.push_str("\n\n");
    prompt.push_str(title);
    prompt.push_str(":\n");
    prompt.push_str(value);
}

fn non_empty(value: &str) -> Option<&str> {
    let trimmed = value.trim();
    (!trimmed.is_empty()).then_some(trimmed)
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
        AsyncDaemonDbSlot, DaemonHttpState, ManagedAgentMutationLocks,
        connect_async_db_for_tests,
    };
    use crate::daemon::state::{DaemonManifest, HostBridgeManifest};
    use crate::daemon::websocket::ReplayBuffer;
    use crate::task_board::dispatch::DispatchLifecycle;
    use crate::task_board::{
        AgentMode, DispatchAppliedTask, TaskBoardItem, TaskBoardPriority, TaskBoardStatus,
        TaskBoardWorkflowState,
    };
    use crate::workspace::utc_now;

    use super::{codex_worker_request, start_interactive_worker, terminal_worker_request};

    #[test]
    fn codex_worker_request_carries_task_board_identity() {
        let applied = applied_task(AgentMode::Headless);

        let request = codex_worker_request(&applied);

        assert_eq!(request.task_id.as_deref(), Some("task-1"));
        assert_eq!(request.board_item_id.as_deref(), Some("board-1"));
        assert_eq!(request.workflow_execution_id.as_deref(), Some("workflow-1"));
        assert!(
            request
                .capabilities
                .contains(&"task-board:item:board-1".to_string())
        );
        assert!(request.prompt.contains("Session task: task-1"));
    }

    #[test]
    fn interactive_worker_request_uses_terminal_runtime() {
        let applied = applied_task(AgentMode::Interactive);

        let request = terminal_worker_request(&applied);

        assert_eq!(request.runtime, "codex");
        assert_eq!(request.task_id.as_deref(), Some("task-1"));
        assert_eq!(request.board_item_id.as_deref(), Some("board-1"));
        assert_eq!(request.rows, 24);
        assert_eq!(request.cols, 80);
    }

    #[tokio::test]
    async fn start_interactive_worker_waits_for_terminal_lane_guard() {
        let state = test_http_state();
        let applied = applied_task(AgentMode::Interactive);
        let outer_guard = state
            .managed_agent_mutation_locks
            .lock(&applied.session_id, "task-board:terminal-worker")
            .await;

        let future = start_interactive_worker(&state, &applied);
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
            sender: sender.clone(),
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
                sender, db_slot, async_db, false,
            ),
            managed_agent_mutation_locks: ManagedAgentMutationLocks::default(),
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
        item.workflow = TaskBoardWorkflowState {
            execution_id: Some("workflow-1".into()),
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
