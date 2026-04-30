use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::agents::acp::supervision::AcpSessionSupervisor;
use crate::daemon::protocol::StreamEvent;
use crate::session::types::AgentStatus;
use crate::workspace::utc_now;

use super::{AcpAgentSnapshot, AcpAgentStartRequest};

pub(super) struct StartedSnapshotInput<'a> {
    pub(super) acp_id: &'a str,
    pub(super) session_id: &'a str,
    pub(super) request: &'a AcpAgentStartRequest,
    pub(super) agent_id: &'a str,
    pub(super) display_name: &'a str,
    pub(super) supervisor: &'a AcpSessionSupervisor,
    pub(super) project_dir: &'a Path,
    pub(super) process_key: &'a str,
    pub(super) permission_log_path: Option<PathBuf>,
}

pub(super) struct ReusedSnapshotInput<'a> {
    pub(super) acp_id: &'a str,
    pub(super) session_id: &'a str,
    pub(super) request: &'a AcpAgentStartRequest,
    pub(super) agent_id: &'a str,
    pub(super) display_name: &'a str,
    pub(super) source: &'a AcpAgentSnapshot,
    pub(super) project_dir: &'a Path,
    pub(super) permission_log_path: Option<PathBuf>,
}

pub(super) fn started_snapshot(input: StartedSnapshotInput<'_>) -> AcpAgentSnapshot {
    let StartedSnapshotInput {
        acp_id,
        session_id,
        request,
        agent_id,
        display_name,
        supervisor,
        project_dir,
        process_key,
        permission_log_path,
    } = input;
    let now = utc_now();
    AcpAgentSnapshot {
        acp_id: acp_id.to_string(),
        session_id: session_id.to_string(),
        agent_id: agent_id.to_string(),
        display_name: display_name.to_string(),
        status: AgentStatus::Active,
        pid: supervisor.pid(),
        pgid: supervisor.pgid(),
        project_dir: project_dir.display().to_string(),
        process_key: process_key.to_string(),
        pending_permissions: 0,
        permission_queue_depth: 0,
        pending_permission_batches: Vec::new(),
        permission_mode: if request.record_permissions {
            "recording".to_string()
        } else {
            "daemon_bridge".to_string()
        },
        permission_log_path: permission_log_path.map(|path| path.display().to_string()),
        terminal_count: 0,
        created_at: now.clone(),
        updated_at: now,
    }
}

pub(super) fn reused_snapshot(input: ReusedSnapshotInput<'_>) -> AcpAgentSnapshot {
    let ReusedSnapshotInput {
        acp_id,
        session_id,
        request,
        agent_id,
        display_name,
        source,
        project_dir,
        permission_log_path,
    } = input;
    let now = utc_now();
    AcpAgentSnapshot {
        acp_id: acp_id.to_string(),
        session_id: session_id.to_string(),
        agent_id: agent_id.to_string(),
        display_name: display_name.to_string(),
        status: AgentStatus::Active,
        pid: source.pid,
        pgid: source.pgid,
        project_dir: project_dir.display().to_string(),
        process_key: source.process_key.clone(),
        pending_permissions: 0,
        permission_queue_depth: 0,
        pending_permission_batches: Vec::new(),
        permission_mode: if request.record_permissions {
            "recording".to_string()
        } else {
            "daemon_bridge".to_string()
        },
        permission_log_path: permission_log_path.map(|path| path.display().to_string()),
        terminal_count: 0,
        created_at: now.clone(),
        updated_at: now,
    }
}

pub(super) fn stream_event(event: &str, payload: &impl Serialize) -> Option<StreamEvent> {
    let payload = serde_json::to_value(payload).ok()?;
    let session_id = payload
        .get("session_id")
        .and_then(serde_json::Value::as_str)
        .map(ToOwned::to_owned);
    Some(StreamEvent {
        event: event.to_string(),
        recorded_at: utc_now(),
        session_id,
        payload,
    })
}

pub(super) fn preferred_project_dir(
    worktree_path: &Path,
    project_dir: Option<&Path>,
    repository_root: Option<&Path>,
    context_root: &Path,
) -> PathBuf {
    if worktree_path.as_os_str().is_empty() {
        project_dir
            .or(repository_root)
            .unwrap_or(context_root)
            .to_path_buf()
    } else {
        worktree_path.to_path_buf()
    }
}
