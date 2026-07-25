use std::sync::{Arc, Mutex, OnceLock};

use tempfile::tempdir;
use tokio::sync::broadcast;

use super::{drain_tick, ensure_escalation_scratch_dir, sanitized_escalation_segment};
use crate::daemon::agent_acp::AcpAgentManagerHandle;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::http::{AsyncDaemonDbSlot, DaemonHttpState, ManagedAgentMutationLocks};
use crate::daemon::state::{DaemonManifest, HostBridgeManifest};
use crate::daemon::websocket::ReplayBuffer;
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TaskBoardTriageEscalationConfig};

#[test]
fn sanitized_segment_keeps_safe_characters_and_replaces_the_rest() {
    assert_eq!(
        sanitized_escalation_segment("triage-escalation-abc123"),
        "triage-escalation-abc123"
    );
    assert_eq!(
        sanitized_escalation_segment("../../etc/passwd"),
        "______etc_passwd"
    );
}

#[tokio::test]
async fn scratch_dir_is_created_empty_under_the_daemon_data_home() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");

    let scratch = ensure_escalation_scratch_dir(&db, "triage-escalation-abc").expect("scratch dir");

    let scratch_path = std::path::Path::new(&scratch);
    assert!(scratch_path.is_dir());
    assert!(
        scratch_path.starts_with(directory.path()),
        "scratch dir lives under the daemon data home, not somewhere unrelated"
    );
    let entries = std::fs::read_dir(scratch_path)
        .expect("read scratch dir")
        .count();
    assert_eq!(entries, 0, "a fresh escalation scratch dir starts empty");
}

#[tokio::test]
async fn ensuring_the_same_scratch_dir_twice_is_idempotent() {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");

    let first = ensure_escalation_scratch_dir(&db, "triage-escalation-abc").expect("first ensure");
    let second = ensure_escalation_scratch_dir(&db, "triage-escalation-abc").expect("second ensure");

    assert_eq!(first, second);
}

/// A minimal, fully-wired `DaemonHttpState` sharing the returned
/// `Arc<AsyncDaemonDb>` with the state's own `async_db` slot, so a test can
/// seed/inspect data through the same handle `drain_tick` will see.
async fn test_state(db_path: &std::path::Path) -> (DaemonHttpState, Arc<AsyncDaemonDb>) {
    let (sender, _) = broadcast::channel(8);
    let db_slot = Arc::new(OnceLock::new());
    let async_db_slot = Arc::new(OnceLock::new());
    let async_db = Arc::new(
        AsyncDaemonDb::connect(db_path)
            .await
            .expect("connect async db"),
    );
    async_db_slot.set(async_db.clone()).expect("install async db");
    let manifest = DaemonManifest {
        version: "0.0.0-test".into(),
        pid: 1,
        endpoint: "http://127.0.0.1:0".into(),
        started_at: "2026-07-24T00:00:00Z".into(),
        token_path: "/tmp/token".into(),
        sandboxed: false,
        host_bridge: HostBridgeManifest::default(),
        revision: 0,
        updated_at: String::new(),
        binary_stamp: None,
        ownership: crate::daemon::state::DaemonOwnership::default(),
    };
    let state = DaemonHttpState {
        token: "token".into(),
        auth_mode: crate::daemon::http::DaemonHttpAuthMode::Local,
        remote_domain: None,
        remote_request_limits: None,
        companion: None,
        remote_pairing_limiter: crate::daemon::http::default_remote_pairing_limiter(),
        remote_pairing_status_limiter: crate::daemon::http::default_remote_pairing_status_limiter(),
        sender: sender.clone(),
        prepared_sender: broadcast::channel(8).0,
        manifest,
        daemon_epoch: "epoch".into(),
        replay_buffer: Arc::new(Mutex::new(ReplayBuffer::new(8))),
        db: db_slot.clone(),
        async_db: AsyncDaemonDbSlot::from_inner(async_db_slot.clone()),
        db_path: Some(db_path.to_path_buf()),
        codex_controller: CodexControllerHandle::new_with_async_db(
            sender.clone(),
            db_slot.clone(),
            async_db_slot.clone(),
            false,
        ),
        acp_agent_manager: AcpAgentManagerHandle::new_with_async_db(
            sender.clone(),
            db_slot.clone(),
            async_db_slot.clone(),
        ),
        agent_tui_manager: AgentTuiManagerHandle::new_with_async_db(
            sender,
            db_slot,
            async_db_slot,
            false,
        ),
        managed_agent_mutation_locks: ManagedAgentMutationLocks::default(),
        recovery_snapshot: Default::default(),
    };
    (state, async_db)
}

/// The store-level test proves `fail_running_task_board_triage_escalation`
/// itself works, but not that `drain_tick` actually calls it when a claimed
/// row's worker spawn errors. Blocking the exact scratch directory
/// `spawn_escalation_worker` will try to create is a deterministic,
/// environment-independent way to force that spawn to fail (no codex binary
/// or host bridge dependency) so this test can observe `drain_tick`'s `Err`
/// handling end to end.
#[tokio::test]
async fn drain_tick_marks_the_row_failed_when_the_worker_spawn_errors() {
    let directory = tempdir().expect("tempdir");
    let db_path = directory.path().join("harness.db");
    let (state, db) = test_state(&db_path).await;
    let config = TaskBoardTriageEscalationConfig {
        enabled: true,
        max_concurrent: 1,
        max_pending: 20,
        timeout_seconds: 180,
    };
    db.set_triage_escalation_config(config);

    let mut item = TaskBoardItem::new(
        "item-1".into(),
        "Vague title".into(),
        String::new(),
        "2026-07-24T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    db.create_task_board_item_with_triage(item)
        .await
        .expect("create item");

    let escalation_id: String = sqlx::query_scalar(
        "SELECT escalation_id FROM task_board_triage_escalations WHERE item_id = 'item-1'",
    )
    .fetch_one(db.pool())
    .await
    .expect("load enqueued escalation id");

    let scratch_base = directory.path().join("triage-escalation-scratch");
    std::fs::create_dir_all(&scratch_base).expect("create scratch base dir");
    std::fs::write(scratch_base.join(&escalation_id), b"not a directory")
        .expect("block the escalation's scratch dir with a plain file");

    drain_tick(&state, &db, &config).await;

    let (status, failure_reason): (String, Option<String>) = sqlx::query_as(
        "SELECT status, failure_reason FROM task_board_triage_escalations WHERE escalation_id = ?1",
    )
    .bind(&escalation_id)
    .fetch_one(db.pool())
    .await
    .expect("load escalation after drain_tick");
    assert_eq!(status, "failed");
    assert!(
        failure_reason.is_some(),
        "a failed spawn must record the real reason, not just flip status"
    );
}
