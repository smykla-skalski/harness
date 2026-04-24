use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::broadcast;

use crate::daemon::agent_tui::{
    AgentTuiManagerHandle, AgentTuiSize, AgentTuiSnapshot, AgentTuiStatus,
};
use crate::daemon::db::DaemonDb;
use crate::session::service as session_service;
use crate::session::types::SessionRole;
use crate::workspace::utc_now;

use super::support::{WAIT_TIMEOUT, sample_snapshot, wait_until, with_agent_tui_home};

#[test]
fn manager_publishes_terminal_output_without_manual_refresh() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_agent_tui_home(tmp.path(), || {
        let project_dir = tmp.path().join("project");
        let context_root = tmp.path().join("context-root");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-tui-live-refresh".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir.clone()),
            checkout_id: "checkout-tui-live-refresh".into(),
            checkout_name: "Directory".into(),
            context_root,
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let state = session_service::build_new_session(
            "live refresh tui test",
            "managed tui",
            "sess-tui-live-refresh",
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
        let (sender, mut receiver) = broadcast::channel(8);
        let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);
        let snapshot = manager
            .start(
                "sess-tui-live-refresh",
                &crate::daemon::agent_tui::AgentTuiStartRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    fallback_role: None,
                    capabilities: vec![],
                    name: Some("Delayed output".into()),
                    prompt: None,
                    project_dir: None,
                    persona: None,
                    argv: vec![
                        "sh".into(),
                        "-c".into(),
                        "sleep 0.2; printf 'agent-ready\\n'; sleep 0.2".into(),
                    ],
                    rows: 30,
                    cols: 120,
                    model: None,
                    effort: None,
                    allow_custom_model: false,
                },
            )
            .expect("start manager TUI");

        let mut updated_snapshot: Option<AgentTuiSnapshot> = None;
        wait_until(WAIT_TIMEOUT, || {
            loop {
                match receiver.try_recv() {
                    Ok(event) if event.event == "agent_tui_updated" => {
                        if let Ok(event_snapshot) =
                            serde_json::from_value::<AgentTuiSnapshot>(event.payload)
                        {
                            if event_snapshot.tui_id == snapshot.tui_id
                                && event_snapshot.screen.text.contains("agent-ready")
                            {
                                updated_snapshot = Some(event_snapshot);
                                return true;
                            }
                        }
                    }
                    Ok(_) => {}
                    Err(tokio::sync::broadcast::error::TryRecvError::Lagged(_)) => {}
                    Err(_) => break,
                }
            }
            false
        });
        let updated_snapshot = updated_snapshot.expect("updated snapshot");
        assert_eq!(updated_snapshot.tui_id, snapshot.tui_id);
        assert!(updated_snapshot.screen.text.contains("agent-ready"));
    });
}

#[test]
fn live_refresh_step_skips_persist_when_db_updated_concurrently() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let context_root = tmp.path().join("context-root");
    fs_err::create_dir_all(&project_dir).expect("project dir");
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-live-refresh".into(),
        name: "project".into(),
        project_dir: Some(project_dir.clone()),
        repository_root: Some(project_dir),
        checkout_id: "checkout-live-refresh".into(),
        checkout_name: "Directory".into(),
        context_root,
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let session_state = session_service::build_new_session(
        "live refresh concurrency",
        "managed tui",
        "sess-live-refresh",
        "claude",
        None,
        &utc_now(),
    );
    db.sync_session(&project.project_id, &session_state)
        .expect("sync session");

    let previous = sample_snapshot(
        "concurrent-live-refresh",
        "sess-live-refresh",
        "agent-live-refresh",
        "codex",
        "2026-04-13T07:00:00Z",
        "2026-04-13T07:00:01Z",
    );
    db.save_agent_tui(&previous)
        .expect("seed previous snapshot");

    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, mut receiver) = broadcast::channel(4);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);

    let mut refreshed = previous.clone();
    refreshed.screen.text = "ready\nlive output".to_string();
    refreshed.updated_at = "2026-04-13T07:00:02Z".to_string();

    let mut concurrent_resize = previous.clone();
    concurrent_resize.size = AgentTuiSize { rows: 48, cols: 80 };
    concurrent_resize.screen.rows = 48;
    concurrent_resize.updated_at = "2026-04-13T07:00:03Z".to_string();
    manager
        .db()
        .expect("manager db")
        .lock()
        .expect("db lock")
        .save_agent_tui(&concurrent_resize)
        .expect("save concurrent resize");

    let skip_status = manager
        .live_refresh_skip_status(&previous.tui_id, &previous.updated_at)
        .expect("live refresh guard");
    if skip_status.is_none() {
        manager
            .persist_refreshed_snapshot(&previous, &refreshed)
            .expect("persist refreshed snapshot");
    }

    assert_eq!(skip_status, Some(AgentTuiStatus::Running));
    assert!(
        receiver.try_recv().is_err(),
        "concurrent resize should suppress stale live-refresh broadcast"
    );
    let persisted = manager
        .load_snapshot(&previous.tui_id)
        .expect("load persisted snapshot");
    assert_eq!(persisted.size, concurrent_resize.size);
    assert_eq!(persisted.updated_at, concurrent_resize.updated_at);
}

#[test]
fn manager_list_prioritizes_leader_tui_over_worker_refresh_order() {
    let db = DaemonDb::open_in_memory().expect("open db");
    let tmp = tempfile::tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let context_root = tmp.path().join("context-root");
    fs_err::create_dir_all(&project_dir).expect("project dir");
    let project = crate::daemon::index::DiscoveredProject {
        project_id: "project-tui-ordering".into(),
        name: "project".into(),
        project_dir: Some(project_dir.clone()),
        repository_root: Some(project_dir),
        checkout_id: "checkout-tui-ordering".into(),
        checkout_name: "Directory".into(),
        context_root,
        is_worktree: false,
        worktree_name: None,
    };
    db.sync_project(&project).expect("sync project");
    let now = utc_now();
    let mut state = session_service::build_new_session(
        "ordering test",
        "ordering",
        "sess-tui-ordering",
        "claude",
        None,
        &now,
    );
    let leader_id = session_service::apply_join_session(
        &mut state,
        "Leader",
        "claude",
        SessionRole::Leader,
        &[],
        Some("claude-leader-session"),
        &now,
        None,
    )
    .expect("join leader");
    let worker_id = "codex-worker".to_string();
    state.agents.insert(
        worker_id.clone(),
        crate::session::types::AgentRegistration {
            agent_id: worker_id.clone(),
            name: "Worker".into(),
            runtime: "codex".into(),
            role: SessionRole::Worker,
            capabilities: vec![],
            joined_at: "2026-04-12T09:00:00Z".into(),
            updated_at: "2026-04-12T09:00:00Z".into(),
            status: crate::session::types::AgentStatus::Active,
            agent_session_id: Some("codex-worker-session".into()),
            last_activity_at: Some("2026-04-12T09:00:00Z".into()),
            current_task_id: None,
            runtime_capabilities: crate::agents::runtime::RuntimeCapabilities::default(),
            persona: None,
        },
    );
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    db.save_agent_tui(&sample_snapshot(
        "leader-tui",
        &state.session_id,
        &leader_id,
        "claude",
        "2026-04-12T09:00:00Z",
        "2026-04-12T09:01:00Z",
    ))
    .expect("save leader tui");
    db.save_agent_tui(&sample_snapshot(
        "worker-tui",
        &state.session_id,
        &worker_id,
        "codex",
        "2026-04-12T09:02:00Z",
        "2026-04-12T09:05:00Z",
    ))
    .expect("save worker tui");

    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, _) = broadcast::channel(4);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);

    let listed = manager
        .list("sess-tui-ordering")
        .expect("list tuis")
        .tuis
        .into_iter()
        .map(|item| item.tui_id)
        .collect::<Vec<_>>();
    assert_eq!(listed, vec!["leader-tui", "worker-tui"]);
}
