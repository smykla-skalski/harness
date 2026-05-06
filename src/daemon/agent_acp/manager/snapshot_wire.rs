use serde::Serialize;

use super::{AcpAgentInspectSnapshot, AcpAgentSnapshot};

#[derive(Serialize)]
struct AcpAgentSnapshotWire<'a> {
    acp_id: &'a str,
    managed_agent_id: &'a str,
    managed_agent_family: crate::session::types::ManagedAgentKind,
    session_id: &'a str,
    agent_id: &'a str,
    session_agent_id: &'a str,
    display_name: &'a str,
    status: &'a crate::session::types::AgentStatus,
    pid: u32,
    pgid: i32,
    project_dir: &'a str,
    process_key: &'a str,
    pending_permissions: usize,
    permission_queue_depth: usize,
    pending_permission_batches: &'a [crate::daemon::agent_acp::AcpPermissionBatch],
    #[serde(skip_serializing_if = "str::is_empty")]
    permission_mode: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    permission_log_path: Option<&'a str>,
    terminal_count: usize,
    created_at: &'a str,
    updated_at: &'a str,
}

#[derive(Serialize)]
struct AcpAgentInspectSnapshotWire<'a> {
    acp_id: &'a str,
    managed_agent_id: &'a str,
    managed_agent_family: crate::session::types::ManagedAgentKind,
    session_id: &'a str,
    agent_id: &'a str,
    session_agent_id: &'a str,
    display_name: &'a str,
    pid: u32,
    pgid: i32,
    #[serde(skip_serializing_if = "str::is_empty")]
    process_key: &'a str,
    uptime_ms: u64,
    last_update_at: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_client_call_at: Option<&'a str>,
    watchdog_state: &'a str,
    #[serde(skip_serializing_if = "str::is_empty")]
    permission_mode: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    permission_log_path: Option<&'a str>,
    pending_permissions: usize,
    permission_queue_depth: usize,
    terminal_count: usize,
    prompt_deadline_remaining_ms: u64,
}

impl Serialize for AcpAgentSnapshot {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        AcpAgentSnapshotWire {
            acp_id: &self.acp_id,
            managed_agent_id: &self.acp_id,
            managed_agent_family: crate::session::types::ManagedAgentKind::Acp,
            session_id: &self.session_id,
            agent_id: &self.agent_id,
            session_agent_id: &self.agent_id,
            display_name: &self.display_name,
            status: &self.status,
            pid: self.pid,
            pgid: self.pgid,
            project_dir: &self.project_dir,
            process_key: &self.process_key,
            pending_permissions: self.pending_permissions,
            permission_queue_depth: self.permission_queue_depth,
            pending_permission_batches: &self.pending_permission_batches,
            permission_mode: &self.permission_mode,
            permission_log_path: self.permission_log_path.as_deref(),
            terminal_count: self.terminal_count,
            created_at: &self.created_at,
            updated_at: &self.updated_at,
        }
        .serialize(serializer)
    }
}

impl Serialize for AcpAgentInspectSnapshot {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        AcpAgentInspectSnapshotWire {
            acp_id: &self.acp_id,
            managed_agent_id: &self.acp_id,
            managed_agent_family: crate::session::types::ManagedAgentKind::Acp,
            session_id: &self.session_id,
            agent_id: &self.agent_id,
            session_agent_id: &self.agent_id,
            display_name: &self.display_name,
            pid: self.pid,
            pgid: self.pgid,
            process_key: &self.process_key,
            uptime_ms: self.uptime_ms,
            last_update_at: &self.last_update_at,
            last_client_call_at: self.last_client_call_at.as_deref(),
            watchdog_state: &self.watchdog_state,
            permission_mode: &self.permission_mode,
            permission_log_path: self.permission_log_path.as_deref(),
            pending_permissions: self.pending_permissions,
            permission_queue_depth: self.permission_queue_depth,
            terminal_count: self.terminal_count,
            prompt_deadline_remaining_ms: self.prompt_deadline_remaining_ms,
        }
        .serialize(serializer)
    }
}

#[cfg(test)]
mod tests {
    use super::{AcpAgentInspectSnapshot, AcpAgentSnapshot};

    #[test]
    fn acp_agent_snapshot_serializes_explicit_identity_fields() {
        let snapshot = AcpAgentSnapshot {
            acp_id: "acp-1".into(),
            session_id: "sess-1".into(),
            agent_id: "worker-1".into(),
            display_name: "Copilot".into(),
            status: crate::session::types::AgentStatus::Active,
            pid: 42,
            pgid: 42,
            project_dir: "/tmp/project".into(),
            process_key: "proc-1".into(),
            pending_permissions: 0,
            permission_queue_depth: 0,
            pending_permission_batches: Vec::new(),
            permission_mode: String::new(),
            permission_log_path: None,
            terminal_count: 0,
            created_at: "2026-05-06T00:00:00Z".into(),
            updated_at: "2026-05-06T00:00:01Z".into(),
        };

        let value = serde_json::to_value(&snapshot).expect("serialize snapshot");
        assert_eq!(value["managed_agent_id"], "acp-1");
        assert_eq!(value["managed_agent_family"], "acp");
        assert_eq!(value["session_agent_id"], "worker-1");
    }

    #[test]
    fn acp_agent_inspect_snapshot_serializes_explicit_identity_fields() {
        let snapshot = AcpAgentInspectSnapshot {
            acp_id: "acp-1".into(),
            session_id: "sess-1".into(),
            agent_id: "worker-1".into(),
            display_name: "Copilot".into(),
            pid: 42,
            pgid: 42,
            process_key: "proc-1".into(),
            uptime_ms: 1_000,
            last_update_at: "2026-05-06T00:00:01Z".into(),
            last_client_call_at: None,
            watchdog_state: "healthy".into(),
            permission_mode: String::new(),
            permission_log_path: None,
            pending_permissions: 0,
            permission_queue_depth: 0,
            terminal_count: 0,
            prompt_deadline_remaining_ms: 10_000,
        };

        let value = serde_json::to_value(&snapshot).expect("serialize inspect snapshot");
        assert_eq!(value["managed_agent_id"], "acp-1");
        assert_eq!(value["managed_agent_family"], "acp");
        assert_eq!(value["session_agent_id"], "worker-1");
    }
}
