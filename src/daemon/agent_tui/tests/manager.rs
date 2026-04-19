use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use tokio::sync::broadcast;

use crate::agents::runtime::{InitialPromptDelivery, runtime_for_name};
use crate::daemon::agent_tui::{AgentTuiManagerHandle, AgentTuiStartRequest, AgentTuiStatus};
use crate::daemon::db::DaemonDb;
use crate::session::service as session_service;
use crate::session::types::SessionRole;
use crate::workspace::utc_now;

use super::support::{WAIT_TIMEOUT, wait_until, with_agent_tui_home};

#[test]
fn refresh_local_snapshot_does_not_rewrite_unchanged_transcript() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_agent_tui_home(tmp.path(), || {
        let project_dir = tmp.path().join("project");
        let context_root = tmp.path().join("context-root");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-tui-transcript-refresh".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir.clone()),
            checkout_id: "checkout-tui-transcript-refresh".into(),
            checkout_name: "Directory".into(),
            context_root,
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let state = session_service::build_new_session(
            "transcript refresh test",
            "managed tui",
            "sess-tui-transcript-refresh",
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
        let (sender, _receiver) = broadcast::channel(8);
        let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);
        let snapshot = manager
            .start(
                "sess-tui-transcript-refresh",
                &AgentTuiStartRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    fallback_role: None,
                    capabilities: vec![],
                    name: Some("Transcript refresh".into()),
                    prompt: None,
                    project_dir: None,
                    persona: None,
                    argv: vec![
                        "sh".into(),
                        "-c".into(),
                        "printf 'steady\\n'; sleep 1".into(),
                    ],
                    rows: 5,
                    cols: 40,
                    model: None,
                    effort: None,
                },
            )
            .expect("start manager TUI");

        wait_until(WAIT_TIMEOUT, || {
            manager
                .refresh_local_snapshot(snapshot.clone())
                .expect("refresh snapshot")
                .screen
                .text
                .contains("steady")
        });

        let refreshed = manager
            .refresh_local_snapshot(snapshot)
            .expect("refresh snapshot");
        assert!(refreshed.screen.text.contains("steady"));

        let transcript_path = PathBuf::from(&refreshed.transcript_path);
        let baseline_modified = fs_err::metadata(&transcript_path)
            .expect("transcript metadata")
            .modified()
            .expect("transcript modified time");

        std::thread::sleep(Duration::from_millis(20));

        let second_refresh = manager
            .refresh_local_snapshot(refreshed)
            .expect("refresh unchanged snapshot");
        assert!(second_refresh.screen.text.contains("steady"));

        let after_modified = fs_err::metadata(&transcript_path)
            .expect("transcript metadata after second refresh")
            .modified()
            .expect("transcript modified time after second refresh");
        assert_eq!(after_modified, baseline_modified);

        manager.stop(&second_refresh.tui_id).expect("stop");
    });
}

#[test]
fn manager_start_does_not_pre_register() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_agent_tui_home(tmp.path(), || {
        let project_dir = tmp.path().join("project");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-no-prereg".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir.clone()),
            checkout_id: "checkout-no-prereg".into(),
            checkout_name: "Directory".into(),
            context_root: tmp.path().join("context"),
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let state = session_service::build_new_session(
            "no prereg test",
            "no prereg",
            "sess-no-prereg",
            "claude",
            None,
            &utc_now(),
        );
        let leader_count = state.agents.len();
        db.sync_session(&project.project_id, &state)
            .expect("sync session");

        let db_slot = Arc::new(OnceLock::new());
        db_slot
            .set(Arc::new(Mutex::new(db)))
            .expect("install test db");
        let (sender, _receiver) = broadcast::channel(8);
        let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);
        let snapshot = manager
            .start(
                "sess-no-prereg",
                &AgentTuiStartRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Worker,
                    fallback_role: None,
                    capabilities: vec![],
                    name: None,
                    prompt: None,
                    project_dir: None,
                    persona: None,
                    argv: vec!["sh".into(), "-c".into(), "printf 'ready\\n'; cat".into()],
                    rows: 5,
                    cols: 40,
                    model: None,
                    effort: None,
                },
            )
            .expect("start");

        assert!(snapshot.agent_id.is_empty());

        {
            let db_guard = db_slot.get().expect("db slot").lock().expect("db lock");
            let loaded = db_guard
                .load_session_state("sess-no-prereg")
                .expect("load state")
                .expect("state present");
            assert_eq!(
                loaded.agents.len(),
                leader_count,
                "only leader should be registered, no TUI agent"
            );
        }

        manager.stop(&snapshot.tui_id).expect("stop");
    });
}

#[test]
fn manager_auto_join_prompt_in_transcript() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_agent_tui_home(tmp.path(), || {
        let project_dir = tmp.path().join("project");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-auto-join".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir.clone()),
            checkout_id: "checkout-auto-join".into(),
            checkout_name: "Directory".into(),
            context_root: tmp.path().join("context"),
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let state = session_service::build_new_session(
            "auto-join test",
            "auto-join",
            "sess-auto-join",
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
        let (sender, _receiver) = broadcast::channel(8);
        let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);
        let snapshot = manager
            .start(
                "sess-auto-join",
                &AgentTuiStartRequest {
                    runtime: "gemini".into(),
                    role: SessionRole::Observer,
                    fallback_role: None,
                    capabilities: vec!["my-cap".into()],
                    name: Some("auto join agent".into()),
                    prompt: None,
                    project_dir: None,
                    persona: None,
                    argv: vec!["sh".into(), "-c".into(), "printf 'ready\\n'; cat".into()],
                    rows: 5,
                    cols: 80,
                    model: None,
                    effort: None,
                },
            )
            .expect("start");

        let prompt = super::super::build_auto_join_prompt(
            "gemini",
            "sess-auto-join",
            SessionRole::Observer,
            None,
            &["my-cap".to_string()],
            &snapshot.tui_id,
            Some("auto join agent"),
            None,
        );
        assert!(prompt.contains("/harness:harness session join"));
        assert!(prompt.contains("sess-auto-join"));
        assert!(prompt.contains("observer"));
        assert!(prompt.contains("my-cap"));
        assert_eq!(
            runtime_for_name("gemini")
                .expect("gemini runtime")
                .initial_prompt_delivery(),
            InitialPromptDelivery::CliFlag("--prompt-interactive")
        );

        manager.stop(&snapshot.tui_id).expect("stop");
    });
}

#[test]
fn manager_start_threads_leader_recovery_prompt_into_process_args() {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_agent_tui_home(tmp.path(), || {
        let project_dir = tmp.path().join("project");
        fs_err::create_dir_all(&project_dir).expect("project dir");
        let db = DaemonDb::open_in_memory().expect("open db");
        let project = crate::daemon::index::DiscoveredProject {
            project_id: "project-recovery-prompt".into(),
            name: "project".into(),
            project_dir: Some(project_dir.clone()),
            repository_root: Some(project_dir.clone()),
            checkout_id: "checkout-recovery-prompt".into(),
            checkout_name: "Directory".into(),
            context_root: tmp.path().join("context"),
            is_worktree: false,
            worktree_name: None,
        };
        db.sync_project(&project).expect("sync project");
        let state = session_service::build_new_session(
            "leader recovery prompt test",
            "recovery prompt",
            "sess-recovery-prompt",
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
        let (sender, _receiver) = broadcast::channel(8);
        let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);
        let snapshot = manager
            .start(
                "sess-recovery-prompt",
                &AgentTuiStartRequest {
                    runtime: "codex".into(),
                    role: SessionRole::Leader,
                    fallback_role: None,
                    capabilities: vec!["policy-preset:swarm-default".into()],
                    name: Some("Recovered codex".into()),
                    prompt: None,
                    project_dir: None,
                    persona: None,
                    argv: vec![
                        "sh".into(),
                        "-c".into(),
                        "printf '%s\\n' \"$@\"; cat".into(),
                        "sh".into(),
                    ],
                    rows: 5,
                    cols: 80,
                    model: None,
                    effort: None,
                },
            )
            .expect("start");

        manager
            .signal_ready(&snapshot.tui_id)
            .expect("signal ready");
        wait_until(WAIT_TIMEOUT, || {
            let screen = manager
                .get(&snapshot.tui_id)
                .expect("refresh snapshot")
                .screen
                .text;
            screen.contains("--role leader") && screen.contains("policy-preset:swarm-default")
        });

        let refreshed = manager.get(&snapshot.tui_id).expect("refresh snapshot");
        assert!(
            refreshed
                .screen
                .text
                .contains("$harness:harness session join")
        );
        assert!(refreshed.screen.text.contains("--role leader"));
        assert!(
            refreshed
                .screen
                .text
                .contains("policy-preset:swarm-default")
        );

        manager.stop(&snapshot.tui_id).expect("stop");
    });
}

#[test]
fn baseline_snapshot_reports_running_state() {
    let status = AgentTuiStatus::Running;
    assert_eq!(status.as_str(), "running");
}
