use serde::de::Error as DeError;
use serde::{Deserialize, Deserializer, Serialize};

use super::models::{
    AcpAgentHandshake, AcpAgentInspectSnapshot, AcpAgentSnapshot, AcpPermissionBatch,
};
use crate::session::{AgentStatus, ManagedAgentKind};

#[derive(Serialize)]
struct AcpAgentSnapshotWire<'a> {
    managed_agent_id: &'a str,
    managed_agent_family: ManagedAgentKind,
    session_id: &'a str,
    session_agent_id: &'a str,
    display_name: &'a str,
    status: &'a AgentStatus,
    pid: u32,
    pgid: i32,
    project_dir: &'a str,
    process_key: &'a str,
    pending_permissions: usize,
    permission_queue_depth: usize,
    pending_permission_batches: &'a [AcpPermissionBatch],
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
    managed_agent_id: &'a str,
    managed_agent_family: ManagedAgentKind,
    session_id: &'a str,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    handshake: Option<&'a AcpAgentHandshake>,
}

#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
struct AcpAgentSnapshotDecode {
    managed_agent_id: String,
    managed_agent_family: ManagedAgentKind,
    session_id: String,
    session_agent_id: String,
    display_name: String,
    status: AgentStatus,
    pid: u32,
    pgid: i32,
    project_dir: String,
    process_key: String,
    pending_permissions: usize,
    permission_queue_depth: usize,
    pending_permission_batches: Vec<AcpPermissionBatch>,
    #[serde(default)]
    permission_mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    permission_log_path: Option<String>,
    terminal_count: usize,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
struct AcpAgentInspectSnapshotDecode {
    managed_agent_id: String,
    managed_agent_family: ManagedAgentKind,
    session_id: String,
    session_agent_id: String,
    display_name: String,
    pid: u32,
    pgid: i32,
    #[serde(default)]
    process_key: String,
    uptime_ms: u64,
    last_update_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    last_client_call_at: Option<String>,
    watchdog_state: String,
    #[serde(default)]
    permission_mode: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    permission_log_path: Option<String>,
    pending_permissions: usize,
    #[serde(default)]
    permission_queue_depth: usize,
    terminal_count: usize,
    prompt_deadline_remaining_ms: u64,
    #[serde(default)]
    handshake: Option<AcpAgentHandshake>,
}

impl Serialize for AcpAgentSnapshot {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        AcpAgentSnapshotWire {
            managed_agent_id: &self.acp_id,
            managed_agent_family: ManagedAgentKind::Acp,
            session_id: &self.session_id,
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

impl<'de> Deserialize<'de> for AcpAgentSnapshot {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let decoded = AcpAgentSnapshotDecode::deserialize(deserializer)?;
        validate_acp_family::<D::Error>(decoded.managed_agent_family)?;
        Ok(Self {
            acp_id: decoded.managed_agent_id,
            session_id: decoded.session_id,
            agent_id: decoded.session_agent_id,
            display_name: decoded.display_name,
            status: decoded.status,
            pid: decoded.pid,
            pgid: decoded.pgid,
            project_dir: decoded.project_dir,
            process_key: decoded.process_key,
            pending_permissions: decoded.pending_permissions,
            permission_queue_depth: decoded.permission_queue_depth,
            pending_permission_batches: decoded.pending_permission_batches,
            permission_mode: decoded.permission_mode,
            permission_log_path: decoded.permission_log_path,
            terminal_count: decoded.terminal_count,
            created_at: decoded.created_at,
            updated_at: decoded.updated_at,
        })
    }
}

impl Serialize for AcpAgentInspectSnapshot {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        AcpAgentInspectSnapshotWire {
            managed_agent_id: &self.acp_id,
            managed_agent_family: ManagedAgentKind::Acp,
            session_id: &self.session_id,
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
            handshake: self.handshake.as_ref(),
        }
        .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for AcpAgentInspectSnapshot {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let decoded = AcpAgentInspectSnapshotDecode::deserialize(deserializer)?;
        validate_acp_family::<D::Error>(decoded.managed_agent_family)?;
        Ok(Self {
            acp_id: decoded.managed_agent_id,
            session_id: decoded.session_id,
            agent_id: decoded.session_agent_id,
            display_name: decoded.display_name,
            pid: decoded.pid,
            pgid: decoded.pgid,
            process_key: decoded.process_key,
            uptime_ms: decoded.uptime_ms,
            last_update_at: decoded.last_update_at,
            last_client_call_at: decoded.last_client_call_at,
            watchdog_state: decoded.watchdog_state,
            permission_mode: decoded.permission_mode,
            permission_log_path: decoded.permission_log_path,
            pending_permissions: decoded.pending_permissions,
            permission_queue_depth: decoded.permission_queue_depth,
            terminal_count: decoded.terminal_count,
            prompt_deadline_remaining_ms: decoded.prompt_deadline_remaining_ms,
            handshake: decoded.handshake,
        })
    }
}

fn validate_acp_family<E>(managed_agent_family: ManagedAgentKind) -> Result<(), E>
where
    E: DeError,
{
    match managed_agent_family {
        ManagedAgentKind::Acp => Ok(()),
        other => Err(E::custom(format!(
            "managed_agent_family must be 'acp', got '{other:?}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::{AcpAgentHandshake, AcpAgentInspectSnapshot, AcpAgentSnapshot};

    #[test]
    fn acp_agent_snapshot_serializes_explicit_identity_fields() {
        let snapshot = AcpAgentSnapshot {
            acp_id: "acp-1".into(),
            session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
            agent_id: "worker-1".into(),
            display_name: "Copilot".into(),
            status: crate::session::AgentStatus::Active,
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
        assert!(value.get("acp_id").is_none());
        assert!(value.get("agent_id").is_none());
    }

    #[test]
    fn acp_agent_inspect_snapshot_serializes_explicit_identity_fields() {
        let snapshot = AcpAgentInspectSnapshot {
            acp_id: "acp-1".into(),
            session_id: "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc".into(),
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
            handshake: None,
        };

        let value = serde_json::to_value(&snapshot).expect("serialize inspect snapshot");
        assert_eq!(value["managed_agent_id"], "acp-1");
        assert_eq!(value["managed_agent_family"], "acp");
        assert_eq!(value["session_agent_id"], "worker-1");
        assert!(value.get("acp_id").is_none());
        assert!(value.get("agent_id").is_none());
        assert!(value.get("handshake").is_none());
    }

    #[test]
    fn acp_agent_inspect_snapshot_round_trips_handshake() {
        let mut snapshot: AcpAgentInspectSnapshot = serde_json::from_value(serde_json::json!({
            "managed_agent_id": "acp-1",
            "managed_agent_family": "acp",
            "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            "session_agent_id": "worker-1",
            "display_name": "Copilot",
            "pid": 42,
            "pgid": 42,
            "uptime_ms": 1_000,
            "last_update_at": "2026-05-06T00:00:01Z",
            "last_client_call_at": null,
            "watchdog_state": "healthy",
            "pending_permissions": 0,
            "permission_queue_depth": 0,
            "terminal_count": 0,
            "prompt_deadline_remaining_ms": 10_000,
        }))
        .expect("decode inspect snapshot without handshake");
        assert_eq!(snapshot.handshake, None);

        snapshot.handshake = Some(AcpAgentHandshake {
            protocol_version: 1,
            agent_name: Some("codex-acp".into()),
            agent_version: Some("0.16.0".into()),
            agent_title: None,
            auth_method_ids: vec!["oauth".into()],
            supports_load_session: true,
            supports_session_list: true,
            ..AcpAgentHandshake::default()
        });
        let value = serde_json::to_value(&snapshot).expect("serialize inspect snapshot");
        assert_eq!(value["handshake"]["protocol_version"], 1);
        assert_eq!(value["handshake"]["agent_name"], "codex-acp");
        let decoded: AcpAgentInspectSnapshot =
            serde_json::from_value(value).expect("decode inspect snapshot with handshake");
        assert_eq!(decoded.handshake, snapshot.handshake);
    }

    #[test]
    fn acp_agent_snapshot_deserializes_canonical_identity_fields() {
        let snapshot: AcpAgentSnapshot = serde_json::from_value(serde_json::json!({
            "managed_agent_id": "acp-1",
            "managed_agent_family": "acp",
            "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            "session_agent_id": "worker-1",
            "display_name": "Copilot",
            "status": "active",
            "pid": 42,
            "pgid": 42,
            "project_dir": "/tmp/project",
            "process_key": "proc-1",
            "pending_permissions": 0,
            "permission_queue_depth": 0,
            "pending_permission_batches": [],
            "terminal_count": 0,
            "created_at": "2026-05-06T00:00:00Z",
            "updated_at": "2026-05-06T00:00:01Z",
        }))
        .expect("decode snapshot");

        assert_eq!(snapshot.acp_id, "acp-1");
        assert_eq!(snapshot.agent_id, "worker-1");
    }

    #[test]
    fn acp_agent_inspect_snapshot_deserializes_canonical_identity_fields() {
        let snapshot: AcpAgentInspectSnapshot = serde_json::from_value(serde_json::json!({
            "managed_agent_id": "acp-1",
            "managed_agent_family": "acp",
            "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            "session_agent_id": "worker-1",
            "display_name": "Copilot",
            "pid": 42,
            "pgid": 42,
            "uptime_ms": 1_000,
            "last_update_at": "2026-05-06T00:00:01Z",
            "last_client_call_at": null,
            "watchdog_state": "healthy",
            "pending_permissions": 0,
            "permission_queue_depth": 0,
            "terminal_count": 0,
            "prompt_deadline_remaining_ms": 10_000,
        }))
        .expect("decode inspect snapshot");

        assert_eq!(snapshot.acp_id, "acp-1");
        assert_eq!(snapshot.agent_id, "worker-1");
    }

    #[test]
    fn acp_agent_snapshot_rejects_missing_managed_agent_family() {
        let error = serde_json::from_value::<AcpAgentSnapshot>(serde_json::json!({
            "managed_agent_id": "acp-1",
            "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            "session_agent_id": "worker-1",
            "display_name": "Copilot",
            "status": "active",
            "pid": 42,
            "pgid": 42,
            "project_dir": "/tmp/project",
            "process_key": "proc-1",
            "pending_permissions": 0,
            "permission_queue_depth": 0,
            "pending_permission_batches": [],
            "terminal_count": 0,
            "created_at": "2026-05-06T00:00:00Z",
            "updated_at": "2026-05-06T00:00:01Z",
        }))
        .expect_err("missing family should fail");

        assert!(
            error.to_string().contains("managed_agent_family"),
            "expected managed_agent_family error, got {error}"
        );
    }

    #[test]
    fn acp_agent_inspect_snapshot_rejects_non_acp_family() {
        let error = serde_json::from_value::<AcpAgentInspectSnapshot>(serde_json::json!({
            "managed_agent_id": "acp-1",
            "managed_agent_family": "tui",
            "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
            "session_agent_id": "worker-1",
            "display_name": "Copilot",
            "pid": 42,
            "pgid": 42,
            "uptime_ms": 1_000,
            "last_update_at": "2026-05-06T00:00:01Z",
            "last_client_call_at": null,
            "watchdog_state": "healthy",
            "pending_permissions": 0,
            "permission_queue_depth": 0,
            "terminal_count": 0,
            "prompt_deadline_remaining_ms": 10_000,
        }))
        .expect_err("wrong family should fail");

        assert!(
            error
                .to_string()
                .contains("managed_agent_family must be 'acp'"),
            "expected acp family error, got {error}"
        );
    }
}
