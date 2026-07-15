use std::collections::BTreeMap;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use tempfile::{TempDir, tempdir};
use tokio::sync::broadcast;

use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::index::DiscoveredProject;
use crate::daemon::protocol::{
    CodexApprovalRequest, CodexRunMode, CodexRunSnapshot, CodexRunStatus, StreamEvent,
    TaskCheckpointRequest,
};
use crate::daemon::service as daemon_service;
use crate::session::service::{self as session_service, TaskSpec};
use crate::session::storage as session_storage;
use crate::session::types::{
    AgentRegistration, AgentStatus, CURRENT_VERSION, ManagedAgentRef, SessionMetrics, SessionRole,
    SessionState, SessionStatus, TaskSeverity, TaskSource,
};

static ASYNC_HARNESS_ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

pub(super) fn codex_approval_request(
    approval_id: &str,
    request_id: &str,
    detail: &str,
) -> CodexApprovalRequest {
    CodexApprovalRequest {
        approval_id: approval_id.to_string(),
        request_id: request_id.to_string(),
        kind: "command".to_string(),
        title: "Command approval requested".to_string(),
        detail: detail.to_string(),
        thread_id: Some("thread-1".to_string()),
        turn_id: Some("turn-1".to_string()),
        item_id: Some(approval_id.to_string()),
        cwd: Some("/tmp/harness".to_string()),
        command: Some("touch approved.txt".to_string()),
        file_path: None,
    }
}

pub(super) fn controller_with_db() -> (CodexControllerHandle, Arc<Mutex<DaemonDb>>, TempDir) {
    controller_with_session_state(sample_session_state())
}

pub(super) fn controller_with_session_state(
    mut state: SessionState,
) -> (CodexControllerHandle, Arc<Mutex<DaemonDb>>, TempDir) {
    let (sender, _) = broadcast::channel::<StreamEvent>(8);
    let tempdir = tempdir().expect("temp dir");
    let project_root = prepare_test_project(&tempdir, &mut state);
    let db_path = tempdir.path().join("harness.db");
    let db = Arc::new(Mutex::new(DaemonDb::open(&db_path).expect("open db")));
    {
        let db_guard = db.lock().expect("db lock");
        db_guard
            .sync_project(&sample_project(&project_root))
            .expect("sync project");
        db_guard
            .save_session_state("project-1", &state)
            .expect("save session");
    }
    let db_slot = Arc::new(OnceLock::new());
    db_slot.set(db.clone()).expect("install db");
    (
        CodexControllerHandle::new(sender, db_slot, false),
        db,
        tempdir,
    )
}

pub(super) async fn controller_with_async_session_state(
    mut state: SessionState,
) -> (CodexControllerHandle, Arc<AsyncDaemonDb>, TempDir) {
    let (sender, _) = broadcast::channel::<StreamEvent>(8);
    let tempdir = tempdir().expect("temp dir");
    let project_root = prepare_test_project(&tempdir, &mut state);
    let async_db = Arc::new(
        AsyncDaemonDb::connect(&tempdir.path().join("harness.db"))
            .await
            .expect("open async db"),
    );
    async_db
        .sync_project(&sample_project(&project_root))
        .await
        .expect("sync project");
    async_db
        .save_session_state("project-1", &state)
        .await
        .expect("save session");
    let layout = session_storage::layout_from_project_dir(&project_root, &state.session_id)
        .expect("session layout");
    assert!(
        session_storage::create_state(&layout, &state).expect("create session file mirror"),
        "async controller fixture must start with the file created by session setup"
    );
    let db_slot = Arc::new(OnceLock::new());
    let async_db_slot = Arc::new(OnceLock::new());
    async_db_slot
        .set(async_db.clone())
        .expect("install async db");
    (
        CodexControllerHandle::new_with_async_db(sender, db_slot, async_db_slot, false),
        async_db,
        tempdir,
    )
}

pub(super) async fn with_isolated_async_harness_env<T, F>(action: impl FnOnce(PathBuf) -> F) -> T
where
    F: Future<Output = T>,
{
    let _guard = ASYNC_HARNESS_ENV_LOCK.lock().await;
    let root = tempdir().expect("isolated harness root");
    let home = root.path().join("home");
    fs_err::create_dir_all(&home).expect("create isolated harness home");
    let root_path = root.path().to_path_buf();
    let future = action(root_path.clone());
    temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(root_path.as_path())),
            ("HOME", Some(home.as_path())),
            ("HARNESS_HOST_HOME", Some(home.as_path())),
            ("HARNESS_DAEMON_DATA_HOME", None::<&Path>),
            ("HARNESS_APP_GROUP_ID", None::<&Path>),
            ("HARNESS_SANDBOXED", None::<&Path>),
            ("CLAUDE_PROJECT_DIR", None::<&Path>),
            ("CLAUDE_SESSION_ID", None::<&Path>),
            ("CODEX_SESSION_ID", None::<&Path>),
            ("GEMINI_SESSION_ID", None::<&Path>),
            ("COPILOT_SESSION_ID", None::<&Path>),
            ("OPENCODE_SESSION_ID", None::<&Path>),
        ],
        future,
    )
    .await
}

pub(super) async fn assert_worker_checkpoint(
    async_db: &AsyncDaemonDb,
    session_id: &str,
    task_id: &str,
    actor: &str,
) {
    let detail = daemon_service::checkpoint_task_async(
        session_id,
        task_id,
        &TaskCheckpointRequest {
            actor: actor.to_string(),
            summary: "Worker checkpointed first-hand.".into(),
            progress: 50,
        },
        async_db,
    )
    .await
    .expect("assigned worker checkpoints through daemon service");
    let checkpoint = detail
        .tasks
        .iter()
        .find(|task| task.task_id == task_id)
        .and_then(|task| task.checkpoint_summary.as_ref())
        .expect("persisted worker checkpoint");
    assert_eq!(checkpoint.actor_id.as_deref(), Some(actor));
    assert_eq!(checkpoint.summary, "Worker checkpointed first-hand.");
    assert_eq!(checkpoint.progress, 50);
}

fn prepare_test_project(tempdir: &TempDir, state: &mut SessionState) -> PathBuf {
    let root = tempdir.path().join("project");
    state.worktree_path = root.join("workspace");
    state.shared_path = root.join("shared");
    state.origin_path = root.clone();
    fs_err::create_dir_all(&state.worktree_path).expect("create test worktree");
    fs_err::create_dir_all(&state.shared_path).expect("create test shared dir");
    root
}

fn sample_project(root: &std::path::Path) -> DiscoveredProject {
    DiscoveredProject {
        project_id: "project-1".into(),
        name: "harness".into(),
        project_dir: Some(root.to_path_buf()),
        repository_root: Some(root.to_path_buf()),
        checkout_id: "checkout-1".into(),
        checkout_name: "main".into(),
        context_root: root.join(".harness"),
        is_worktree: false,
        worktree_name: None,
    }
}

fn sample_session_state() -> SessionState {
    SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 1,
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        project_name: "harness".into(),
        worktree_path: PathBuf::from("/tmp/harness/workspace"),
        shared_path: PathBuf::from("/tmp/harness/shared"),
        origin_path: PathBuf::from("/tmp/harness"),
        branch_ref: "harness/eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        title: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        context: "codex controller test".into(),
        status: SessionStatus::AwaitingLeader,
        policy: Default::default(),
        created_at: "2026-04-09T10:00:00Z".into(),
        updated_at: "2026-04-09T10:00:01Z".into(),
        agents: BTreeMap::new(),
        tasks: BTreeMap::new(),
        leader_id: None,
        archived_at: None,
        last_activity_at: Some("2026-04-09T10:00:01Z".into()),
        observe_id: None,
        pending_leader_transfer: None,
        external_origin: None,
        adopted_at: None,
        metrics: SessionMetrics::default(),
    }
}

pub(super) fn sample_session_state_with_codex_agent(status: AgentStatus) -> SessionState {
    let mut state = sample_session_state();
    state.agents.insert(
        "agent-1".into(),
        AgentRegistration {
            agent_id: "agent-1".into(),
            name: "Codex Worker".into(),
            runtime: "codex".into(),
            role: SessionRole::Leader,
            capabilities: Vec::new(),
            joined_at: "2026-04-09T10:00:00Z".into(),
            updated_at: "2026-04-09T10:00:01Z".into(),
            status,
            agent_session_id: None,
            managed_agent: Some(ManagedAgentRef::codex("codex-run-1")),
            last_activity_at: Some("2026-04-09T10:00:01Z".into()),
            current_task_id: None,
            runtime_capabilities: Default::default(),
            persona: None,
        },
    );
    state.status = SessionStatus::Active;
    state.leader_id = Some("agent-1".into());
    state.metrics = SessionMetrics::recalculate(&state);
    state
}

pub(super) fn sample_session_state_with_open_task() -> SessionState {
    let mut state = sample_session_state();
    add_open_task(&mut state);
    state
}

pub(super) fn sample_session_state_with_open_task_and_codex_agent() -> SessionState {
    let mut state = sample_session_state_with_codex_agent(AgentStatus::Active);
    add_open_task(&mut state);
    state
}

fn add_open_task(state: &mut SessionState) {
    session_service::apply_create_task_with_id(
        state,
        "task-1",
        &TaskSpec {
            title: "Implement task binding",
            context: None,
            severity: TaskSeverity::Medium,
            suggested_fix: None,
            source: TaskSource::Manual,
            observe_issue_id: None,
        },
        crate::session::types::CONTROL_PLANE_ACTOR_ID,
        "2026-04-09T10:00:02Z",
    )
    .expect("create task");
}

pub(super) fn codex_run_snapshot(status: CodexRunStatus) -> CodexRunSnapshot {
    CodexRunSnapshot {
        run_id: "codex-run-1".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        task_id: None,
        board_item_id: None,
        workflow_execution_id: None,
        session_agent_id: Some("agent-1".into()),
        display_name: Some("Codex Worker".into()),
        project_dir: "/tmp/harness".into(),
        thread_id: Some("thread-1".into()),
        turn_id: Some("turn-1".into()),
        mode: CodexRunMode::WorkspaceWrite,
        status,
        prompt: "Investigate".into(),
        latest_summary: Some("Running".into()),
        final_message: None,
        error: None,
        pending_approvals: vec![codex_approval_request("approval-1", "request-1", "Approve")],
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: "2026-04-09T10:00:00Z".into(),
        updated_at: "2026-04-09T10:00:01Z".into(),
        model: Some("gpt-5.5".into()),
        effort: Some("high".into()),
    }
}
