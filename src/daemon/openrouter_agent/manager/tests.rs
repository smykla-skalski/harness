use std::collections::BTreeSet;
use std::path::PathBuf;
use std::sync::Arc;

use tempfile::TempDir;
use tokio::sync::broadcast;

use crate::agents::acp::client::HarnessAcpClient;
use crate::agents::acp::permission::PermissionMode;
use crate::agents::openrouter::AgentConfig as OpenRouterAgentConfig;
use crate::daemon::agent_acp::permission_bridge::PermissionBridgeHandle;
use crate::daemon::protocol::StreamEvent;
use crate::session::types::ManagedAgentKind;
use crate::workspace::utc_now;

use super::{
    DEFAULT_OPENROUTER_MODEL, OpenRouterAgentManagerHandle, OpenRouterRunSnapshot,
    OpenRouterRunStatus, SessionEntry, lock_sessions,
};

fn manager_with_no_subscribers() -> OpenRouterAgentManagerHandle {
    let (sender, _rx) = broadcast::channel::<StreamEvent>(4);
    OpenRouterAgentManagerHandle::new(sender)
}

#[test]
fn list_for_session_filters_by_harness_session() {
    let manager = manager_with_no_subscribers();
    {
        let mut sessions = lock_sessions(&manager.inner);
        sessions.insert(
            "openrouter-a".into(),
            seed_entry("openrouter-a", "session-1"),
        );
        sessions.insert(
            "openrouter-b".into(),
            seed_entry("openrouter-b", "session-2"),
        );
    }
    let runs = manager.list_for_session("session-1").runs;
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].run_id, "openrouter-a");
}

#[test]
fn get_returns_not_found_for_unknown_run() {
    let manager = manager_with_no_subscribers();
    let err = manager.get("missing").expect_err("missing should be 404");
    assert!(err.to_string().to_lowercase().contains("not found"));
}

#[test]
fn cancel_marks_status_cancelled() {
    let manager = manager_with_no_subscribers();
    {
        let mut sessions = lock_sessions(&manager.inner);
        sessions.insert("openrouter-a".into(), seed_entry("openrouter-a", "s"));
    }
    let snapshot = manager.cancel("openrouter-a").expect("cancel ok");
    assert_eq!(snapshot.status, OpenRouterRunStatus::Cancelled);
}

fn seed_entry(run_id: &str, harness_session: &str) -> SessionEntry {
    let now = utc_now();
    let tmpdir = TempDir::new().expect("tmpdir");
    let project_dir: PathBuf = tmpdir.path().to_path_buf();
    let tool_client = Arc::new(HarnessAcpClient::new(
        project_dir.clone(),
        project_dir.clone(),
        None,
        BTreeSet::new(),
        PermissionMode::Recording {
            log_path: project_dir.join("permission-log.ndjson"),
        },
    ));
    let (bridge_sender, _bridge_rx) = broadcast::channel::<StreamEvent>(4);
    let permissions = PermissionBridgeHandle::spawn_with_kind(
        run_id.to_owned(),
        harness_session.to_owned(),
        ManagedAgentKind::OpenRouter,
        bridge_sender,
    );
    // The TempDir guard would clean up the project directory as soon as this
    // helper returns. The integration tests below only inspect snapshot
    // state, so we intentionally leak the guard to keep paths valid for the
    // life of the test process.
    std::mem::forget(tmpdir);
    SessionEntry {
        snapshot: OpenRouterRunSnapshot {
            run_id: run_id.to_owned(),
            session_id: harness_session.to_owned(),
            session_agent_id: None,
            display_name: "OpenRouter".to_owned(),
            model: DEFAULT_OPENROUTER_MODEL.to_owned(),
            status: OpenRouterRunStatus::Pending,
            latest_message: None,
            latest_reasoning: None,
            final_message: None,
            error: None,
            turn_count: 0,
            pending_permission_batches: Vec::new(),
            created_at: now.clone(),
            updated_at: now,
        },
        history: Vec::new(),
        config: OpenRouterAgentConfig {
            api_key: "sk-test".to_owned(),
            base_url: "https://example.test/v1".to_owned(),
            http_referer: "https://harness.dev".to_owned(),
            x_title: "Harness".to_owned(),
        },
        active_turn: None,
        temperature: None,
        max_tokens: None,
        reasoning_effort: None,
        project_dir,
        tool_client,
        permissions,
    }
}
