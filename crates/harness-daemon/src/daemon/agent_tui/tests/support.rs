use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use crate::daemon::agent_tui::{
    AgentTuiBackend, AgentTuiLaunchProfile, AgentTuiProcess, AgentTuiSize, AgentTuiSnapshot,
    AgentTuiSpawnSpec, AgentTuiStatus, PortablePtyAgentTuiBackend, TerminalScreenSnapshot,
};
use crate::daemon::protocol::StreamEvent;

pub(super) const WAIT_TIMEOUT: Duration = super::super::DEFAULT_WAIT_TIMEOUT;

pub(super) fn sample_snapshot(
    tui_id: &str,
    session_id: &str,
    agent_id: &str,
    runtime: &str,
    created_at: &str,
    updated_at: &str,
) -> AgentTuiSnapshot {
    AgentTuiSnapshot {
        tui_id: tui_id.to_string(),
        session_id: session_id.to_string(),
        agent_id: agent_id.to_string(),
        runtime: runtime.to_string(),
        status: AgentTuiStatus::Running,
        argv: vec![runtime.to_string()],
        project_dir: "/tmp/project".to_string(),
        size: AgentTuiSize { rows: 24, cols: 80 },
        screen: TerminalScreenSnapshot {
            rows: 24,
            cols: 80,
            cursor_row: 1,
            cursor_col: 1,
            text: "ready".to_string(),
        },
        transcript_path: "/tmp/transcript.log".to_string(),
        exit_code: None,
        signal: None,
        error: None,
        created_at: created_at.to_string(),
        updated_at: updated_at.to_string(),
    }
}

pub(super) fn spawn_shell(script: &str) -> AgentTuiProcess {
    let profile = AgentTuiLaunchProfile::from_argv(
        "codex",
        vec!["sh".to_string(), "-c".to_string(), script.to_string()],
    )
    .expect("profile");
    let spec = AgentTuiSpawnSpec::new(
        profile,
        PathBuf::from("."),
        BTreeMap::new(),
        AgentTuiSize { rows: 5, cols: 40 },
    )
    .expect("spec");
    PortablePtyAgentTuiBackend
        .spawn(spec)
        .expect("spawn pty process")
}

pub(super) fn spawn_runtime(runtime: &str) -> AgentTuiProcess {
    let profile = AgentTuiLaunchProfile::for_runtime(runtime).expect("profile");
    let spec = AgentTuiSpawnSpec::new(
        profile,
        PathBuf::from("."),
        BTreeMap::new(),
        AgentTuiSize { rows: 5, cols: 40 },
    )
    .expect("spec");
    PortablePtyAgentTuiBackend
        .spawn(spec)
        .expect("spawn runtime")
}

pub(super) fn spawn_shell_with_readiness(
    script: &str,
    readiness_pattern: Option<&'static str>,
) -> AgentTuiProcess {
    let profile = AgentTuiLaunchProfile::from_argv(
        "codex",
        vec!["sh".to_string(), "-c".to_string(), script.to_string()],
    )
    .expect("profile");
    let mut spec = AgentTuiSpawnSpec::new(
        profile,
        PathBuf::from("."),
        BTreeMap::new(),
        AgentTuiSize { rows: 5, cols: 40 },
    )
    .expect("spec");
    spec.readiness_pattern = readiness_pattern;
    PortablePtyAgentTuiBackend
        .spawn(spec)
        .expect("spawn pty process")
}

pub(super) fn write_executable_script(path: &Path, contents: &str) {
    if let Some(parent) = path.parent() {
        fs_err::create_dir_all(parent).expect("create script dir");
    }
    fs_err::write(path, contents).expect("write script");
    let mut permissions = fs_err::metadata(path).expect("metadata").permissions();
    std::os::unix::fs::PermissionsExt::set_mode(&mut permissions, 0o755);
    fs_err::set_permissions(path, permissions).expect("chmod script");
}

pub(super) fn wait_until(timeout: Duration, mut condition: impl FnMut() -> bool) {
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if condition() {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(condition(), "condition should become true before timeout");
}

pub(super) fn recv_broadcast_events(
    receiver: &mut tokio::sync::broadcast::Receiver<StreamEvent>,
    count: usize,
    timeout: Duration,
) -> Vec<StreamEvent> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("create broadcast receive runtime");
    let deadline = std::time::Instant::now() + timeout;
    let mut events = Vec::new();
    while events.len() < count {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            break;
        }
        match runtime.block_on(async { tokio::time::timeout(remaining, receiver.recv()).await }) {
            Ok(Ok(event)) => events.push(event),
            Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => {}
            Ok(Err(tokio::sync::broadcast::error::RecvError::Closed)) | Err(_) => break,
        }
    }
    events
}

pub(super) fn with_agent_tui_home<T>(base: &Path, action: impl FnOnce() -> T) -> T {
    let home = base.join("home");
    fs_err::create_dir_all(&home).expect("create agent tui home");
    temp_env::with_vars(
        [
            ("HOME", Some(home.as_path())),
            ("HARNESS_HOST_HOME", Some(home.as_path())),
        ],
        action,
    )
}
