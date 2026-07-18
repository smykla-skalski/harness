use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use tempfile::tempdir;
use tokio::sync::broadcast;

use super::{ProductionTaskBoardReadOnlyRuntime, TaskBoardReadOnlyRuntime};
use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::http::{
    AsyncDaemonDbSlot, DaemonHttpAuthMode, DaemonHttpState, ManagedAgentMutationLocks,
    default_remote_pairing_limiter, default_remote_pairing_status_limiter,
};
use crate::daemon::protocol::{CodexRunMode, CodexRunSnapshot, CodexRunStatus, StreamEvent};
use crate::daemon::websocket::ReplayBuffer;
use crate::session::types::{CURRENT_VERSION, SessionMetrics, SessionState, SessionStatus};

#[tokio::test(flavor = "multi_thread")]
async fn production_load_reconciles_unattached_active_report_after_restart() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("harness.db");
    let db = Arc::new(
        AsyncDaemonDb::connect(&db_path)
            .await
            .expect("open async database"),
    );
    let run = active_report_run();
    seed_session(db.as_ref(), &run.session_id).await;
    db.save_codex_run(&run).await.expect("save active run");
    let state = restarted_state(&db_path, db.clone());
    let runtime = ProductionTaskBoardReadOnlyRuntime::new(&state, db.as_ref());

    let reconciled = runtime
        .load_codex_report_run(&run.run_id)
        .await
        .expect("load reconciled run")
        .expect("durable run");

    assert_eq!(reconciled.status, CodexRunStatus::Failed);
    assert_eq!(
        reconciled.error.as_deref(),
        Some("Codex turn is no longer attached to this daemon")
    );
    assert_eq!(
        db.codex_run(&run.run_id)
            .await
            .expect("reload run")
            .expect("persisted run")
            .status,
        CodexRunStatus::Failed
    );
}

async fn seed_session(db: &AsyncDaemonDb, session_id: &str) {
    let state = SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 1,
        session_id: session_id.into(),
        project_name: "harness".into(),
        worktree_path: PathBuf::from("/tmp/read-only-worktree"),
        shared_path: PathBuf::from("/tmp/read-only-shared"),
        origin_path: PathBuf::from("/tmp/harness"),
        branch_ref: "harness/restart".into(),
        title: "restart".into(),
        context: "restart recovery".into(),
        status: SessionStatus::AwaitingLeader,
        policy: Default::default(),
        created_at: "2026-07-17T23:58:00Z".into(),
        updated_at: "2026-07-17T23:58:00Z".into(),
        agents: BTreeMap::new(),
        tasks: BTreeMap::new(),
        leader_id: None,
        archived_at: None,
        last_activity_at: None,
        observe_id: None,
        pending_leader_transfer: None,
        external_origin: None,
        adopted_at: None,
        metrics: SessionMetrics::default(),
    };
    let state_json = serde_json::to_string(&state).expect("serialize session state");
    sqlx::query(
        "INSERT INTO projects (
         project_id, name, project_dir, repository_root, checkout_id,
         checkout_name, context_root, is_worktree, discovered_at, updated_at
         ) VALUES ('project-restart', 'harness', '/tmp/harness', '/tmp/harness',
                   'checkout-restart', 'main', '/tmp/data/project-restart', 0,
                   '2026-07-17T23:58:00Z', '2026-07-17T23:58:00Z')",
    )
    .execute(db.pool())
    .await
    .expect("seed project");
    sqlx::query(
        "INSERT INTO sessions (
         session_id, project_id, schema_version, state_version, title, context,
         status, created_at, updated_at, metrics_json, state_json, is_active
         ) VALUES (?1, 'project-restart', 3, 1, 'restart', 'restart', 'active',
                   '2026-07-17T23:58:00Z', '2026-07-17T23:58:00Z', '{}', ?2, 1)",
    )
    .bind(session_id)
    .bind(state_json)
    .execute(db.pool())
    .await
    .expect("seed session");
}

fn restarted_state(db_path: &std::path::Path, async_db: Arc<AsyncDaemonDb>) -> DaemonHttpState {
    let (sender, _) = broadcast::channel::<StreamEvent>(8);
    let db = Arc::new(OnceLock::new());
    db.set(Arc::new(Mutex::new(
        DaemonDb::open(db_path).expect("open synchronous database"),
    )))
    .expect("install synchronous database");
    let async_db_slot = Arc::new(OnceLock::new());
    async_db_slot.set(async_db).expect("install async database");
    DaemonHttpState {
        token: "token".into(),
        auth_mode: DaemonHttpAuthMode::Local,
        remote_domain: None,
        remote_request_limits: None,
        remote_pairing_limiter: default_remote_pairing_limiter(),
        remote_pairing_status_limiter: default_remote_pairing_status_limiter(),
        sender: sender.clone(),
        prepared_sender: broadcast::channel(8).0,
        manifest: serde_json::from_value(serde_json::json!({
            "version": "48.5.0",
            "pid": 1,
            "endpoint": "http://127.0.0.1:0",
            "started_at": "2026-07-18T00:00:00Z",
            "token_path": "/tmp/token",
            "sandboxed": false,
            "host_bridge": {},
            "revision": 0,
            "updated_at": "",
            "binary_stamp": null
        }))
        .expect("daemon manifest"),
        daemon_epoch: "restart-epoch".into(),
        replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
        db: db.clone(),
        async_db: AsyncDaemonDbSlot::from_inner(async_db_slot.clone()),
        db_path: Some(db_path.to_path_buf()),
        codex_controller: CodexControllerHandle::new_with_async_db(
            sender.clone(),
            db.clone(),
            async_db_slot.clone(),
            false,
        ),
        acp_agent_manager: AcpAgentManagerHandle::new_with_async_db(
            sender.clone(),
            db.clone(),
            async_db_slot.clone(),
        ),
        agent_tui_manager: AgentTuiManagerHandle::new_with_async_db(
            sender,
            db,
            async_db_slot,
            false,
        ),
        managed_agent_mutation_locks: ManagedAgentMutationLocks::default(),
        recovery_snapshot: Default::default(),
    }
}

fn active_report_run() -> CodexRunSnapshot {
    CodexRunSnapshot {
        run_id: "codex-workflow-restart-review-1".into(),
        session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
        task_id: None,
        board_item_id: Some("item-restart".into()),
        workflow_execution_id: Some("execution-restart".into()),
        session_agent_id: Some("agent-restart".into()),
        display_name: Some("Task Board Review".into()),
        project_dir: "/tmp/read-only-worktree".into(),
        thread_id: Some("thread-restart".into()),
        turn_id: Some("turn-restart".into()),
        mode: CodexRunMode::Report,
        status: CodexRunStatus::Running,
        prompt: "frozen read-only report prompt".into(),
        latest_summary: Some("report running".into()),
        final_message: None,
        error: None,
        pending_approvals: Vec::new(),
        resolved_approvals: Vec::new(),
        events: Vec::new(),
        created_at: "2026-07-17T23:59:00Z".into(),
        updated_at: "2026-07-17T23:59:00Z".into(),
        model: Some("gpt-5.3-codex".into()),
        effort: Some("high".into()),
    }
}
