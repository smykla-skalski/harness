use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use harness::daemon::agent_tui::{AgentTuiManagerHandle, AgentTuiSnapshot, AgentTuiStatus};
use harness::daemon::db::DaemonDb;
use harness::session::service;
use tokio::sync::broadcast;

use super::*;

#[test]
fn sandboxed_recovery_prompt_routes_through_bridge() {
    let tmp = tempdir().expect("tempdir");
    let host_home = ensure_host_home(tmp.path());
    let project = tmp.path().join("project");
    std::fs::create_dir_all(&project).expect("create project");

    let mock_bin = tmp.path().join("bin");
    std::fs::create_dir_all(&mock_bin).expect("create mock bin");
    write_mock_codex_tui(&mock_bin);
    let path_env = prefixed_path_env(&mock_bin);

    let mut bridge = ManagedChild::spawn(
        Command::new(harness_binary())
            .args(["bridge", "start", "--capability", "agent-tui"])
            .env("HARNESS_DAEMON_DATA_HOME", tmp.path())
            .env("XDG_DATA_HOME", tmp.path())
            .env("HARNESS_HOST_HOME", &host_home)
            .env("HOME", &host_home)
            .env("PATH", &path_env)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped()),
    )
    .expect("spawn bridge");
    let _state = wait_for_bridge_state(tmp.path());

    let request = with_bridge_env(tmp.path(), &host_home, || {
        let state = service::start_session_with_policy(
            "bridge recovery",
            "",
            &project,
            Some("claude"),
            Some("bridge-recovery"),
            Some("swarm-default"),
        )
        .expect("start session");
        let leader_id = state.leader_id.clone().expect("leader id");
        service::leave_session("bridge-recovery", &leader_id, &project).expect("leave leader");
        service::build_recovery_tui_request("bridge-recovery", "swarm-default", "codex", &project)
            .expect("build request")
    });

    let current_state = with_bridge_env(tmp.path(), &host_home, || {
        service::session_status("bridge-recovery", &project)
    })
    .expect("session status");
    let db_path = tmp.path().join("daemon.sqlite3");
    let db = DaemonDb::open(&db_path).expect("open daemon db");
    let discovered = harness::daemon::index::discovered_project_for_checkout(&project);
    db.sync_project(&discovered).expect("sync project");
    db.sync_session(&discovered.project_id, &current_state)
        .expect("sync session");

    let db_slot = std::sync::Arc::new(std::sync::OnceLock::new());
    db_slot
        .set(std::sync::Arc::new(std::sync::Mutex::new(db)))
        .expect("install db");
    let (sender, _receiver) = broadcast::channel(8);
    let manager = AgentTuiManagerHandle::new(sender, std::sync::Arc::clone(&db_slot), true);
    let snapshot = with_bridge_env(tmp.path(), &host_home, || {
        manager.start("bridge-recovery", &request)
    })
    .expect("start via bridge");
    assert_eq!(snapshot.status, AgentTuiStatus::Running);

    let shown = with_bridge_env(tmp.path(), &host_home, || {
        wait_for_bridge_prompt(&manager, &snapshot.tui_id)
    });
    assert!(shown.screen.text.contains("/harness:session:join"));
    assert!(shown.screen.text.contains("--role leader"));
    assert!(shown.screen.text.contains("policy-preset:swarm-default"));

    with_bridge_env(tmp.path(), &host_home, || manager.stop(&snapshot.tui_id)).expect("stop");
    let stop_output = run_bridge(&tmp, &["bridge", "stop"]);
    assert!(
        stop_output.status.success(),
        "bridge stop failed: {}",
        output_text(&stop_output)
    );
    wait_for_bridge_exit(&mut bridge);
}

fn with_bridge_env<T>(root: &Path, host_home: &Path, action: impl FnOnce() -> T) -> T {
    let root_str = root.to_str().expect("utf8 root");
    let host_str = host_home.to_str().expect("utf8 host home");
    temp_env::with_vars(
        [
            ("HARNESS_DAEMON_DATA_HOME", Some(root_str)),
            ("XDG_DATA_HOME", Some(root_str)),
            ("HARNESS_HOST_HOME", Some(host_str)),
            ("HOME", Some(host_str)),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_SANDBOXED", Some("1")),
        ],
        action,
    )
}

fn prefixed_path_env(prefix: &Path) -> std::ffi::OsString {
    let mut paths = vec![prefix.to_path_buf()];
    if let Some(existing) = std::env::var_os("PATH") {
        paths.extend(std::env::split_paths(&existing));
    }
    std::env::join_paths(paths).expect("join PATH")
}

fn write_mock_codex_tui(bin_dir: &Path) {
    let script = bin_dir.join("codex");
    std::fs::write(
        &script,
        r#"#!/bin/sh
if [ "$1" = "--version" ]; then
  echo 'mock-codex 0.0.1'
  exit 0
fi

printf 'mock-codex-ready\n'
printf '%s\n' "$@"
exec cat
"#,
    )
    .expect("write mock codex");
    std::fs::set_permissions(
        &script,
        std::fs::Permissions::from(std::os::unix::fs::PermissionsExt::from_mode(0o755)),
    )
    .expect("chmod mock codex");
}

fn wait_for_bridge_prompt(manager: &AgentTuiManagerHandle, tui_id: &str) -> AgentTuiSnapshot {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    loop {
        let snapshot = manager.get(tui_id).expect("refresh bridge snapshot");
        if snapshot.screen.text.contains("--role leader")
            && snapshot.screen.text.contains("policy-preset:swarm-default")
        {
            return snapshot;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "bridge recovery prompt did not surface before timeout"
        );
        thread::sleep(Duration::from_millis(100));
    }
}
