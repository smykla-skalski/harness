use std::env::temp_dir;
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::broadcast;
use uuid::Uuid;

use super::*;
use crate::daemon::agent_tui::AgentTuiManagerHandle;
use crate::daemon::codex_controller::CodexControllerHandle;
use crate::daemon::db::{AsyncDaemonDb, DaemonDb};
use crate::daemon::state::DaemonManifest;

mod agent_tuis;
mod codex;
mod managed_agents;
mod sessions;

pub(super) async fn test_http_state_with_async_db_only() -> DaemonHttpState {
    build_async_http_state(false).await
}

pub(super) async fn test_http_state_with_async_db_timeline_only() -> DaemonHttpState {
    build_async_http_state(true).await
}

async fn build_async_http_state(seed_timeline: bool) -> DaemonHttpState {
    let (sender, _) = broadcast::channel(8);
    let db_slot = Arc::new(OnceLock::new());
    let async_db_slot = Arc::new(OnceLock::new());
    let db_path = temp_dir().join(format!("harness-http-test-async-{}.db", Uuid::new_v4()));
    let db = DaemonDb::open(&db_path).expect("open file db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    db.save_session_state(&project.project_id, &sample_session_state())
        .expect("save session state");
    if seed_timeline {
        db.sync_conversation_events(
            "sess-test-1",
            "codex-worker",
            "codex",
            &[sample_tool_result_event()],
        )
        .expect("sync conversation events");
    }
    drop(db);

    assert!(
        async_db_slot
            .set(Arc::new(
                AsyncDaemonDb::connect(&db_path)
                    .await
                    .expect("open async daemon db"),
            ))
            .is_ok(),
        "install async db"
    );

    let manifest = test_daemon_manifest();

    DaemonHttpState {
        token: "token".into(),
        sender: sender.clone(),
        manifest,
        daemon_epoch: "epoch".into(),
        replay_buffer: Arc::new(Mutex::new(crate::daemon::websocket::ReplayBuffer::new(8))),
        db: db_slot.clone(),
        async_db: super::super::AsyncDaemonDbSlot::from_inner(async_db_slot.clone()),
        db_path: Some(db_path),
        codex_controller: CodexControllerHandle::new_with_async_db(
            sender.clone(),
            db_slot.clone(),
            async_db_slot.clone(),
            false,
        ),
        agent_tui_manager: AgentTuiManagerHandle::new_with_async_db(
            sender,
            db_slot,
            async_db_slot,
            false,
        ),
    }
}

fn test_daemon_manifest() -> DaemonManifest {
    serde_json::from_value(serde_json::json!({
        "version": "20.6.0",
        "pid": 1,
        "endpoint": "http://127.0.0.1:0",
        "started_at": "2026-04-13T00:00:00Z",
        "token_path": "/tmp/token",
        "sandboxed": false,
        "host_bridge": {},
        "revision": 0,
        "updated_at": "",
        "binary_stamp": null,
    }))
    .expect("deserialize daemon manifest")
}
