use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};

use tokio::sync::broadcast;

use super::AcpAgentManagerHandle;
use crate::agents::runtime::RuntimeCapabilities;
use crate::daemon::db::DaemonDb;
use crate::daemon::index::DiscoveredProject;
use crate::daemon::protocol::StreamEvent;
use crate::session::types::{
    AgentRegistration, AgentStatus, CURRENT_VERSION, SessionMetrics, SessionRole, SessionState,
    SessionStatus,
};

pub(super) fn seeded_manager() -> AcpAgentManagerHandle {
    let (sender, _) = broadcast::channel(16);
    seeded_manager_with_sender(sender)
}

pub(super) fn seeded_manager_with_events()
-> (AcpAgentManagerHandle, broadcast::Receiver<StreamEvent>) {
    let (sender, receiver) = broadcast::channel(64);
    (seeded_manager_with_sender(sender), receiver)
}

fn seeded_manager_with_sender(sender: broadcast::Sender<StreamEvent>) -> AcpAgentManagerHandle {
    let db = Arc::new(Mutex::new(seed_daemon_db()));
    let db_cell = Arc::new(OnceLock::new());
    db_cell.set(Arc::clone(&db)).expect("seed ACP manager db");
    AcpAgentManagerHandle::new(sender, db_cell)
}

fn seed_daemon_db() -> DaemonDb {
    let db = DaemonDb::open_in_memory().expect("open db");
    let project = sample_project();
    db.sync_project(&project).expect("sync project");
    for session_id in ["sess-1", "sess-2", "sess-3", "sess-4"] {
        db.sync_session(&project.project_id, &sample_session_state(session_id))
            .expect("sync session");
    }
    db
}

fn sample_project() -> DiscoveredProject {
    DiscoveredProject {
        project_id: "project-abc123".into(),
        name: "harness".into(),
        project_dir: Some("/tmp/harness".into()),
        repository_root: Some("/tmp/harness".into()),
        checkout_id: "checkout-abc123".into(),
        checkout_name: "Repository".into(),
        context_root: "/tmp/data/projects/project-abc123".into(),
        is_worktree: false,
        worktree_name: None,
    }
}

fn sample_session_state(session_id: &str) -> SessionState {
    let mut agents = BTreeMap::new();
    agents.insert(
        "claude-leader".into(),
        AgentRegistration {
            agent_id: "claude-leader".into(),
            name: "Claude Leader".into(),
            runtime: "claude".into(),
            role: SessionRole::Leader,
            capabilities: vec!["general".into()],
            joined_at: "2026-04-03T12:00:00Z".into(),
            updated_at: "2026-04-03T12:05:00Z".into(),
            status: AgentStatus::Active,
            agent_session_id: Some("claude-session-1".into()),
            managed_agent: None,
            last_activity_at: Some("2026-04-03T12:05:00Z".into()),
            current_task_id: None,
            runtime_capabilities: RuntimeCapabilities::default(),
            persona: None,
        },
    );

    SessionState {
        schema_version: CURRENT_VERSION,
        state_version: 1,
        session_id: session_id.to_string(),
        project_name: String::new(),
        worktree_path: PathBuf::new(),
        shared_path: PathBuf::new(),
        origin_path: PathBuf::new(),
        branch_ref: String::new(),
        title: session_id.to_string(),
        context: "test session".into(),
        status: SessionStatus::Active,
        policy: Default::default(),
        created_at: "2026-04-03T12:00:00Z".into(),
        updated_at: "2026-04-03T12:05:00Z".into(),
        agents,
        tasks: BTreeMap::new(),
        leader_id: Some("claude-leader".into()),
        archived_at: None,
        last_activity_at: Some("2026-04-03T12:05:00Z".into()),
        observe_id: None,
        pending_leader_transfer: None,
        external_origin: None,
        adopted_at: None,
        metrics: SessionMetrics::default(),
    }
}

#[cfg(unix)]
pub(super) fn write_executable(path: &Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;

    fs::write(path, body).expect("write script");
    let mut permissions = fs::metadata(path).expect("metadata").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(path, permissions).expect("chmod script");
}

#[cfg(unix)]
pub(super) fn write_sleeping_acp_agent(path: &Path) {
    write_executable(path, &fake_acp_agent_script(None, None, None));
}

#[cfg(unix)]
pub(super) fn write_cancel_recording_acp_agent(path: &Path, cancel_log: &Path) {
    write_executable(path, &fake_acp_agent_script(None, None, Some(cancel_log)));
}

#[cfg(unix)]
pub(super) fn write_prompt_delaying_acp_agent(path: &Path, delay_seconds: f32) {
    write_executable(
        path,
        &fake_acp_agent_script(None, Some(delay_seconds), None),
    );
}

#[cfg(unix)]
pub(super) fn write_exiting_acp_agent(path: &Path, delay_seconds: f32, code: i32) {
    write_executable(
        path,
        &fake_acp_agent_script(Some((delay_seconds, code)), None, None),
    );
}

#[cfg(unix)]
fn fake_acp_agent_script(
    exit: Option<(f32, i32)>,
    prompt_delay: Option<f32>,
    cancel_log: Option<&Path>,
) -> String {
    let exit_setup = exit.map_or_else(String::new, |(delay, code)| {
        format!("threading.Timer({delay}, lambda: os._exit({code})).start()\n",)
    });
    let prompt_delay = prompt_delay.unwrap_or(0.0);
    let cancel_log = cancel_log
        .map(|path| format!("{:?}", path.display().to_string()))
        .unwrap_or_else(|| "None".to_string());
    format!(
        r#"#!/usr/bin/env python3
import json
import os
import sys
import threading
import time

{exit_setup}next_session = 1
prompt_delay = {prompt_delay}
cancel_log = {cancel_log}
for line in sys.stdin:
    message = json.loads(line)
    method = message.get("method")
    if method == "initialize":
        result = {{"protocolVersion": message.get("params", {{}}).get("protocolVersion", 1),
                  "agentCapabilities": {{}}}}
    elif method == "session/new":
        result = {{"sessionId": f"acp-session-{{next_session}}"}}
        next_session += 1
    elif method == "session/prompt":
        if prompt_delay > 0:
            time.sleep(prompt_delay)
        result = {{"stopReason": "end_turn"}}
    elif method == "session/cancel":
        if cancel_log is not None:
            params = message.get("params", {{}})
            session_id = params.get("sessionId") or params.get("session_id") or message.get("sessionId") or ""
            with open(cancel_log, "a", encoding="utf-8") as handle:
                handle.write(session_id + "\n")
        continue
    else:
        result = {{}}
    if "id" in message:
        print(json.dumps({{"jsonrpc": "2.0", "id": message["id"], "result": result}}),
              flush=True)
"#
    )
}
