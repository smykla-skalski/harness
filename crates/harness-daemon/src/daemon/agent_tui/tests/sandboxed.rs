use std::collections::BTreeMap;
use std::io::ErrorKind;
use std::os::unix::net::UnixListener;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

use tokio::sync::broadcast;

use crate::daemon::agent_tui::{
    ActiveAgentTui, AgentTuiManagerHandle, AgentTuiSize, AgentTuiSnapshot, AgentTuiStartRequest,
    AgentTuiStatus, TerminalScreenSnapshot,
};
use crate::daemon::bridge::{
    BRIDGE_CAPABILITY_AGENT_TUI, BridgeState, acquire_bridge_lock_exclusive, bridge_state_path,
};
use crate::daemon::db::DaemonDb;
use crate::daemon::db::prelude::*;
use crate::daemon::db_handle::DaemonDbOwnedHandle;
use crate::daemon::state::HostBridgeCapabilityManifest;
use crate::session::service as session_service;
use crate::session::types::SessionRole;
use crate::workspace::utc_now;

use super::support::sample_snapshot;
use crate::daemon::agent_tui::manager_workspace_lifecycle::normalize_started_workspace_snapshot;

#[test]
fn sandboxed_bridge_snapshot_preserves_durable_workspace_owner() {
    let db = DaemonDbOwnedHandle(DaemonDb::open_in_memory().expect("open db"));
    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, _) = broadcast::channel(8);
    let manager = AgentTuiManagerHandle::new(sender, db_slot, true);
    let mut previous = sample_snapshot(
        "agent-tui-adopted",
        "workspace-owner",
        "",
        "codex",
        "2026-08-09T10:00:00Z",
        "2026-08-09T10:00:01Z",
    );
    previous.workspace_id = Some("workspace-owner".into());
    let bridge = sample_snapshot(
        "agent-tui-adopted",
        "legacy-session",
        "legacy-agent",
        "codex",
        "2026-08-09T10:00:00Z",
        "2026-08-09T10:00:02Z",
    );

    let normalized = manager.normalize_bridge_snapshot(&previous, bridge);

    assert_eq!(normalized.workspace_id.as_deref(), Some("workspace-owner"));
    assert_eq!(normalized.session_id, "workspace-owner");
    assert!(normalized.agent_id.is_empty());
}

#[test]
fn sandboxed_list_returns_an_active_cached_snapshot_without_bridge_rpc() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let daemon_home = tmp.path().join("daemon-home");
    let host_home = tmp.path().join("host-home");
    fs_err::create_dir_all(&host_home).expect("host home");
    temp_env::with_vars(
        [
            ("HARNESS_DAEMON_DATA_HOME", daemon_home.to_str()),
            ("HARNESS_APP_GROUP_ID", None),
            ("XDG_DATA_HOME", None),
            ("HARNESS_HOST_HOME", host_home.to_str()),
            ("HOME", host_home.to_str()),
        ],
        || {
            with_counting_fake_bridge(&tmp, |rpc_count| {
                assert_sandboxed_list_uses_cached_snapshot(&tmp, &rpc_count);
            });
        },
    );
}

fn assert_sandboxed_list_uses_cached_snapshot(tmp: &tempfile::TempDir, rpc_count: &AtomicUsize) {
    let db = DaemonDbOwnedHandle(DaemonDb::open_in_memory().expect("open db"));
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-list-test".into(),
        name: "project".into(),
        project_dir: Some(tmp.path().join("project")),
        repository_root: Some(tmp.path().join("project")),
        checkout_id: "checkout-list-test".into(),
        checkout_name: "Directory".into(),
        context_root: tmp.path().join("context-root"),
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let session = session_service::build_new_session(
        "list test",
        "list test",
        "6bb2d489-b2ac-5b23-a08c-f9cb6d3d1aaf",
        "claude",
        None,
        &utc_now(),
    );
    db.sync_session(&project.project_id, &session)
        .expect("sync session");
    let snapshot = sample_snapshot(
        "agent-tui-list-test",
        &session.session_id,
        "agent-list-test",
        "codex",
        "2026-08-09T10:00:00Z",
        "2026-08-09T10:00:01Z",
    );
    db.save_agent_tui(&snapshot).expect("save cached snapshot");
    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, _) = broadcast::channel(8);
    let manager = AgentTuiManagerHandle::new(sender, db_slot, true);
    manager
        .active()
        .expect("active map")
        .insert(snapshot.tui_id.clone(), ActiveAgentTui::new(None));

    let listed = manager.list(&session.session_id).expect("list cached TUI");

    assert_eq!(listed.tuis, vec![snapshot]);
    assert_eq!(rpc_count.load(Ordering::Relaxed), 0);
}

fn with_counting_fake_bridge(tmp: &tempfile::TempDir, operation: impl FnOnce(Arc<AtomicUsize>)) {
    let socket_path = tmp.path().join("bridge.sock");
    let listener = UnixListener::bind(&socket_path).expect("bind fake bridge");
    listener
        .set_nonblocking(true)
        .expect("make fake bridge nonblocking");
    let token_path = tmp.path().join("bridge.token");
    fs_err::write(&token_path, "test-token\n").expect("write bridge token");
    let _bridge_lock = acquire_bridge_lock_exclusive().expect("hold bridge lock");
    let bridge_state = BridgeState {
        socket_path: socket_path.display().to_string(),
        pid: std::process::id(),
        started_at: "2026-08-09T10:00:00Z".into(),
        token_path: token_path.display().to_string(),
        capabilities: BTreeMap::from([(
            BRIDGE_CAPABILITY_AGENT_TUI.into(),
            HostBridgeCapabilityManifest {
                enabled: true,
                healthy: true,
                transport: "unix".into(),
                endpoint: Some(socket_path.display().to_string()),
                metadata: BTreeMap::new(),
            },
        )]),
    };
    fs_err::write(
        bridge_state_path(),
        serde_json::to_vec(&bridge_state).expect("serialize bridge state"),
    )
    .expect("write bridge state");

    let stop_server = Arc::new(AtomicBool::new(false));
    let rpc_count = Arc::new(AtomicUsize::new(0));
    let server_stop = Arc::clone(&stop_server);
    let server_count = Arc::clone(&rpc_count);
    let server = thread::spawn(move || {
        while !server_stop.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok((stream, _)) => {
                    server_count.fetch_add(1, Ordering::Relaxed);
                    drop(stream);
                }
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(2));
                }
                Err(error) => panic!("accept fake bridge request: {error}"),
            }
        }
    });
    let operation_result = catch_unwind(AssertUnwindSafe(|| operation(Arc::clone(&rpc_count))));
    stop_server.store(true, Ordering::Relaxed);
    server.join().expect("join fake bridge");
    if let Err(payload) = operation_result {
        resume_unwind(payload);
    }
}

#[test]
fn sandboxed_workspace_start_normalizes_a_pre_upgrade_bridge_snapshot() {
    let bridge = sample_snapshot(
        "agent-tui-started",
        "legacy-session",
        "legacy-agent",
        "codex",
        "2026-08-09T10:00:00Z",
        "2026-08-09T10:00:01Z",
    );

    let normalized = normalize_started_workspace_snapshot(bridge, "workspace-owner");

    assert_eq!(normalized.workspace_id.as_deref(), Some("workspace-owner"));
    assert_eq!(normalized.session_id, "workspace-owner");
    assert!(normalized.agent_id.is_empty());
}

#[test]
fn sandboxed_stop_without_bridge_falls_back_to_local_cleanup() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let daemon_home = tmp.path().join("daemon-home");
    fs_err::create_dir_all(&project_dir).expect("project dir");
    let db = DaemonDb::open_in_memory().expect("open db");
    let db = DaemonDbOwnedHandle(db);
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-stop-test".into(),
        name: "project".into(),
        project_dir: Some(project_dir.clone()),
        repository_root: Some(project_dir),
        checkout_id: "checkout-stop-test".into(),
        checkout_name: "Directory".into(),
        context_root: tmp.path().join("context-root"),
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let session_state = session_service::build_new_session(
        "stop test",
        "stop test",
        "65b1e884-aced-5040-a647-c1b3cda701c4",
        "claude",
        None,
        &utc_now(),
    );
    db.sync_session(&project.project_id, &session_state)
        .expect("sync session");
    let now = utc_now();

    let snapshot = AgentTuiSnapshot {
        tui_id: "agent-tui-test-stop".into(),
        session_id: "65b1e884-aced-5040-a647-c1b3cda701c4".into(),
        workspace_id: None,
        agent_id: "agent-stop-test".into(),
        runtime: "codex".into(),
        status: AgentTuiStatus::Running,
        argv: vec!["sh".into(), "-c".into(), "printf 'ready\\n'; cat".into()],
        project_dir: tmp.path().display().to_string(),
        size: AgentTuiSize { rows: 24, cols: 80 },
        screen: TerminalScreenSnapshot {
            rows: 24,
            cols: 80,
            cursor_row: 0,
            cursor_col: 0,
            text: String::new(),
        },
        transcript_path: tmp.path().join("transcript.jsonl").display().to_string(),
        exit_code: None,
        signal: None,
        error: None,
        created_at: now.clone(),
        updated_at: now,
    };
    db.save_agent_tui(&snapshot).expect("seed snapshot");

    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, mut receiver) = broadcast::channel(8);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), true);

    let active = ActiveAgentTui::new(None);
    manager
        .active()
        .expect("active map")
        .insert("agent-tui-test-stop".into(), active);

    let stopped = temp_env::with_vars(
        [(
            "HARNESS_DAEMON_DATA_HOME",
            Some(daemon_home.to_str().expect("utf8 daemon home")),
        )],
        || manager.stop("agent-tui-test-stop"),
    )
    .expect("stop should succeed without bridge");

    assert_eq!(stopped.status, AgentTuiStatus::Stopped);
    assert_eq!(stopped.tui_id, "agent-tui-test-stop");

    let event = receiver.try_recv().expect("stopped event");
    assert_eq!(event.event, "agent_tui_stopped");
}

#[test]
fn sandboxed_start_without_bridge_does_not_join_agent() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let context_root = tmp.path().join("context-root");
    let daemon_home = tmp.path().join("daemon-home");
    fs_err::create_dir_all(&project_dir).expect("project dir");
    let db = DaemonDb::open_in_memory().expect("open db");
    let db = DaemonDbOwnedHandle(db);
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-tui-manager".into(),
        name: "project".into(),
        project_dir: Some(project_dir.clone()),
        repository_root: Some(project_dir),
        checkout_id: "checkout-tui-manager".into(),
        checkout_name: "Directory".into(),
        context_root,
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let state = session_service::build_new_session(
        "managed tui test",
        "managed tui",
        "f7db1185-850b-5f7d-8679-169d0d7cd520",
        "claude",
        None,
        &utc_now(),
    );
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, _) = broadcast::channel(8);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), true);

    temp_env::with_vars(
        [(
            "HARNESS_DAEMON_DATA_HOME",
            Some(daemon_home.to_str().expect("utf8 daemon home")),
        )],
        || {
            let error = manager
                .start(
                    "f7db1185-850b-5f7d-8679-169d0d7cd520",
                    &AgentTuiStartRequest {
                        runtime: "copilot".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: Some("Copilot TUI".into()),
                        prompt: Some("hello".into()),
                        project_dir: None,
                        persona: None,
                        task_id: None,
                        board_item_id: None,
                        workflow_execution_id: None,
                        argv: vec![],
                        rows: 24,
                        cols: 80,
                        model: None,
                        effort: None,
                        allow_custom_model: false,
                    },
                )
                .expect_err("start should fail without bridge");

            assert!(error.message().contains("agent-tui.host-bridge"));
        },
    );

    let db_guard = db_slot.get().expect("db slot").lock().expect("db lock");
    let state = db_guard
        .load_session_state("f7db1185-850b-5f7d-8679-169d0d7cd520")
        .expect("load state")
        .expect("state present");
    assert!(state.agents.values().all(|agent| {
        agent
            .capabilities
            .iter()
            .all(|capability| capability != "agent-tui")
    }));
}
