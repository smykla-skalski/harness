use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::agent_tui::{
    AgentTuiLaunchProfile, AgentTuiManagerHandle, AgentTuiSize, AgentTuiSnapshot,
    AgentTuiStartRequest, AgentTuiStatus,
};
use harness::daemon::bridge::{AgentTuiStartSpec, BridgeClient, BridgeStatusReport};
use harness::daemon::db::DaemonDb;
use harness::daemon::protocol::{SessionStartRequest, StreamEvent};
use harness::daemon::service as daemon_service;
use harness::session::types::SessionRole;
use tempfile::tempdir;
use tokio::sync::broadcast;

use self::support::{
    ensure_host_home, harness_binary, output_text, run_bridge, run_bridge_with_data_home,
    wait_for_bridge_exit, wait_for_bridge_state,
};
use super::helpers::ManagedChild;

const BRIDGE_WAIT_TIMEOUT: Duration = Duration::from_secs(10);
const BRIDGE_POLL_INTERVAL: Duration = Duration::from_millis(100);

mod recovery;
mod support;

#[test]
fn bridge_status_reports_not_running_when_clean() {
    let tmp = tempdir().expect("tempdir");
    let output = run_bridge(&tmp, &["bridge", "status"]);
    assert!(output.status.success(), "status: {}", output_text(&output));

    let report: BridgeStatusReport = serde_json::from_slice(&output.stdout).expect("parse");
    assert!(!report.running);
    assert!(report.socket_path.is_none());
}

#[test]
fn bridge_start_refuses_when_sandboxed() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let output = Command::new(harness_binary())
        .args(["bridge", "start", "--capability", "agent-tui"])
        .env("HARNESS_SANDBOXED", "1")
        .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path())
        .env("HARNESS_HOST_HOME", &host_home)
        .env("HOME", &host_home)
        .output()
        .expect("run harness");
    assert!(!output.status.success());

    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("SANDBOX001") || stderr.contains("sandbox"),
        "expected sandbox error: {stderr}"
    );
}

#[test]
fn bridge_start_publishes_agent_tui_capability_and_stops_cleanly() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());

    let mut bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args(["bridge", "start", "--capability", "agent-tui"])
            .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path())
            .env("HARNESS_HOST_HOME", &host_home)
            .env("HOME", &host_home)
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .expect("spawn bridge");

    let state = wait_for_bridge_state(tmp.path());
    assert!(state.pid > 0);
    assert!(
        state.socket_path.ends_with("harness/daemon/bridge.sock"),
        "unexpected socket path: {}",
        state.socket_path
    );
    let capability = state
        .capabilities
        .get("agent-tui")
        .expect("agent-tui capability");
    assert_eq!(capability.transport, "unix");
    assert_eq!(
        capability
            .metadata
            .get("active_sessions")
            .map(String::as_str),
        Some("0")
    );

    let status_output = run_bridge(&tmp, &["bridge", "status"]);
    assert!(
        status_output.status.success(),
        "status: {}",
        output_text(&status_output)
    );
    let report: BridgeStatusReport = serde_json::from_slice(&status_output.stdout).expect("parse");
    assert!(report.running);
    assert!(report.capabilities.contains_key("agent-tui"));
    assert!(!report.capabilities.contains_key("codex"));

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "stop: {}",
        output_text(&stop_output)
    );

    let state_path = tmp.path().join("harness/daemon/bridge.json");
    assert!(!state_path.exists(), "state file should be cleaned up");

    let deadline = Instant::now() + BRIDGE_WAIT_TIMEOUT;
    loop {
        if bridge.try_wait().expect("poll bridge").is_some() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "bridge process did not exit after stop"
        );
        thread::sleep(BRIDGE_POLL_INTERVAL);
    }
}

#[test]
fn bridge_start_daemon_uses_short_socket_path_for_long_data_home() {
    let tmp = tempdir().expect("tempdir");
    let data_home = tmp.path().join(
        "deep/nesting/that/makes/the/default/daemon/socket/path/too/long/for/macos/unix/domain/sockets",
    );
    std::fs::create_dir_all(&data_home).expect("create data home");

    let output = run_bridge_with_data_home(
        &data_home,
        &["bridge", "start", "--daemon", "--capability", "agent-tui"],
    );
    assert!(output.status.success(), "start: {}", output_text(&output));

    let state = wait_for_bridge_state(&data_home);
    assert!(PathBuf::from(&state.socket_path).starts_with("/tmp"));
    assert!(
        state.socket_path.len() < 103,
        "socket path should fit unix-domain limits: {}",
        state.socket_path
    );
    let status_output = run_bridge_with_data_home(&data_home, &["bridge", "status"]);
    assert!(
        status_output.status.success(),
        "status: {}",
        output_text(&status_output)
    );
    let report: BridgeStatusReport =
        serde_json::from_slice(&status_output.stdout).expect("parse daemon bridge status");
    assert!(
        report.running,
        "daemon start should return only after the bridge is live"
    );
    assert_eq!(
        report.socket_path.as_deref(),
        Some(state.socket_path.as_str())
    );

    let stop_output = run_bridge_with_data_home(&data_home, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "stop: {}",
        output_text(&stop_output)
    );
    assert!(
        !PathBuf::from(&state.socket_path).exists(),
        "socket should be removed after stop"
    );
}

#[test]
fn bridge_reconfigure_requires_force_to_disable_agent_tui_with_active_sessions() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let project = tmp.path().join("project");
    crate::integration::daemon_control::process::init_git_repo(&project);

    let mut bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args(["bridge", "start", "--capability", "agent-tui"])
            .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path())
            .env("HARNESS_HOST_HOME", &host_home)
            .env("HOME", &host_home)
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .expect("spawn bridge");

    let _state = wait_for_bridge_state(tmp.path());
    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            (
                "HARNESS_HOST_HOME",
                Some(host_home.to_str().expect("utf8 host home")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_SANDBOXED", None),
        ],
        || {
            let client = BridgeClient::from_state_file().expect("bridge client");
            let snapshot = client
                .agent_tui_start(&AgentTuiStartSpec {
                    session_id: "session-1".to_string(),
                    agent_id: "agent-1".to_string(),
                    tui_id: "agent-tui-1".to_string(),
                    profile: AgentTuiLaunchProfile::from_argv(
                        "codex",
                        vec!["sh".to_string(), "-c".to_string(), "cat".to_string()],
                    )
                    .expect("launch profile"),
                    project_dir: project.clone(),
                    transcript_path: tmp.path().join("transcript.log"),
                    size: AgentTuiSize { rows: 24, cols: 80 },
                    prompt: None,
                    effort: None,
                })
                .expect("start agent tui");
            assert_eq!(snapshot.tui_id, "agent-tui-1");
        },
    );

    let output = run_bridge(&tmp, &["bridge", "reconfigure", "--disable", "agent-tui"]);
    assert!(
        !output.status.success(),
        "disable should fail without force: {}",
        output_text(&output)
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("KSRCLI092") || stderr.contains("--force"));

    let forced_output = run_bridge(
        &tmp,
        &[
            "bridge",
            "reconfigure",
            "--disable",
            "agent-tui",
            "--force",
            "--json",
        ],
    );
    assert!(
        forced_output.status.success(),
        "forced disable: {}",
        output_text(&forced_output)
    );
    let report: BridgeStatusReport =
        serde_json::from_slice(&forced_output.stdout).expect("parse status");
    assert!(!report.capabilities.contains_key("agent-tui"));

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut bridge);
}

#[test]
fn sandboxed_agent_tui_publishes_live_refresh_over_bridge() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let project = tmp.path().join("project");
    crate::integration::daemon_control::process::init_git_repo(&project);

    let mut bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args(["bridge", "start", "--capability", "agent-tui"])
            .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path())
            .env("HARNESS_HOST_HOME", &host_home)
            .env("HOME", &host_home)
            .env_remove("HARNESS_APP_GROUP_ID")
            .env_remove("HARNESS_SANDBOXED")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .expect("spawn bridge");

    let _state = wait_for_bridge_state(tmp.path());

    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 daemon root")),
            ),
            (
                "HARNESS_HOST_HOME",
                Some(host_home.to_str().expect("utf8 host home")),
            ),
            ("HOME", Some(host_home.to_str().expect("utf8 host home"))),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_SANDBOXED", Some("1")),
        ],
        || {
            let db_path = tmp.path().join("daemon.sqlite3");
            let db = DaemonDb::open(&db_path).expect("open daemon db");
            let session_state = daemon_service::start_session_direct(
                &SessionStartRequest {
                    title: "sandboxed tui live refresh".into(),
                    context: "sandboxed tui".into(),
                    runtime: "codex".into(),
                    session_id: Some("sess-sandbox-tui".into()),
                    project_dir: project.to_string_lossy().into_owned(),
                    policy_preset: None,
                },
                Some(&db),
            )
            .expect("start session");
            let session_id = session_state.session_id.clone();

            let db_slot = Arc::new(OnceLock::new());
            db_slot.set(Arc::new(Mutex::new(db))).expect("install db");
            let (sender, mut receiver) = broadcast::channel::<StreamEvent>(64);
            let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), true);

            let snapshot = manager
                .start(
                    &session_id,
                    &AgentTuiStartRequest {
                        runtime: "codex".into(),
                        role: SessionRole::Worker,
                        fallback_role: None,
                        capabilities: vec![],
                        name: Some("Sandboxed live refresh".into()),
                        prompt: None,
                        project_dir: Some(project.to_string_lossy().into_owned()),
                        argv: vec![
                            "sh".into(),
                            "-c".into(),
                            "printf 'agent-ready\\n'; sleep 2".into(),
                        ],
                        rows: 30,
                        cols: 120,
                        persona: None,
                        model: None,
                        effort: None,
                        allow_custom_model: false,
                    },
                )
                .expect("start sandboxed tui via bridge");
            assert_eq!(snapshot.status, AgentTuiStatus::Running);

            let started = receiver.try_recv().expect("started event must be queued");
            assert_eq!(started.event, "agent_tui_started");

            let mut updated: Option<AgentTuiSnapshot> = None;
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline && updated.is_none() {
                match receiver.try_recv() {
                    Ok(event) => {
                        if event.event != "agent_tui_updated" {
                            continue;
                        }
                        let event_snapshot: AgentTuiSnapshot =
                            serde_json::from_value(event.payload.clone())
                                .expect("decode updated snapshot");
                        if event_snapshot.tui_id == snapshot.tui_id
                            && event_snapshot.screen.text.contains("agent-ready")
                        {
                            updated = Some(event_snapshot);
                        }
                    }
                    Err(broadcast::error::TryRecvError::Empty) => {
                        thread::sleep(Duration::from_millis(20));
                    }
                    Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
                    Err(broadcast::error::TryRecvError::Closed) => {
                        panic!("broadcast channel closed before receiving live refresh event");
                    }
                }
            }

            let updated = updated.expect(
                "sandboxed daemon should publish an agent_tui_updated event whose screen text contains the PTY output",
            );
            assert_eq!(updated.tui_id, snapshot.tui_id);
            assert!(updated.screen.text.contains("agent-ready"));
            assert!(
                updated.status == AgentTuiStatus::Running
                    || updated.status == AgentTuiStatus::Exited
            );

            let _ = manager.stop(&snapshot.tui_id);
        },
    );

    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "cleanup stop: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut bridge);
}

/// Verify the full readiness callback flow: start a TUI, call signal_ready
/// from a separate thread (simulating the SessionStart hook), and verify the
/// agent_tui_ready event is broadcast.
#[test]
fn readiness_callback_triggers_agent_tui_ready_event() {
    let tmp = tempdir().expect("tempdir");
    let project_dir = tmp.path().join("project");
    let db_path = tmp.path().join("harness.db");
    std::fs::create_dir_all(&project_dir).expect("project dir");

    let db = DaemonDb::open(&db_path).expect("open db");
    let project = harness::daemon::index::discovered_project_for_checkout(&project_dir);
    db.sync_project(&project).expect("sync project");

    let state = temp_env::with_vars(
        [("XDG_DATA_HOME", Some(tmp.path().to_str().expect("utf8")))],
        || {
            harness::session::service::start_session(
                "readiness callback test",
                "readiness",
                &project_dir,
                Some("codex"),
                Some("sess-readiness-cb"),
            )
            .expect("start session")
        },
    );
    db.sync_session(&project.project_id, &state)
        .expect("sync session");

    let db_slot = Arc::new(OnceLock::new());
    db_slot
        .set(Arc::new(Mutex::new(db)))
        .expect("install test db");
    let (sender, mut receiver) = broadcast::channel(16);
    let manager = AgentTuiManagerHandle::new(sender, Arc::clone(&db_slot), false);

    let snapshot = manager
        .start(
            "sess-readiness-cb",
            &AgentTuiStartRequest {
                runtime: "codex".into(),
                role: SessionRole::Worker,
                fallback_role: None,
                capabilities: vec![],
                name: Some("callback test".into()),
                prompt: None,
                project_dir: Some(project_dir.to_string_lossy().into()),
                persona: None,
                argv: vec!["sh".into(), "-c".into(), "printf 'ready\\n'; cat".into()],
                rows: 30,
                cols: 120,
                model: None,
                effort: None,
                allow_custom_model: false,
            },
        )
        .expect("start TUI");
    assert_eq!(snapshot.status, AgentTuiStatus::Running);

    // Simulate the SessionStart hook callback after a short delay.
    let manager_clone = manager.clone();
    let tui_id = snapshot.tui_id.clone();
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(200));
        let _ = manager_clone.signal_ready(&tui_id);
    });

    // Wait for the agent_tui_ready event.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut saw_ready = false;
    while Instant::now() < deadline && !saw_ready {
        match receiver.try_recv() {
            Ok(event) if event.event == "agent_tui_ready" => saw_ready = true,
            Ok(_) => {}
            Err(broadcast::error::TryRecvError::Lagged(_)) => {}
            Err(_) => thread::sleep(Duration::from_millis(20)),
        }
    }
    assert!(
        saw_ready,
        "agent_tui_ready event should be broadcast after callback"
    );

    let _ = manager.stop(&snapshot.tui_id);
}
