use serde::{Deserialize, Serialize};

use crate::agents::runtime::signal::{AckResult, Signal, SignalAck};

use super::{SessionRole, TaskSeverity, TaskStatus};

/// Session-visible signal status for CLI and daemon rendering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionSignalStatus {
    Pending,
    #[serde(alias = "acknowledged")]
    Delivered,
    Rejected,
    Deferred,
    Expired,
}

impl SessionSignalStatus {
    #[must_use]
    pub fn from_ack_result(result: AckResult) -> Self {
        match result {
            AckResult::Accepted => Self::Delivered,
            AckResult::Rejected => Self::Rejected,
            AckResult::Deferred => Self::Deferred,
            AckResult::Expired => Self::Expired,
        }
    }
}

/// A signal visible within a multi-agent session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSignalRecord {
    pub runtime: String,
    pub agent_id: String,
    pub session_id: String,
    pub status: SessionSignalStatus,
    pub signal: Signal,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acknowledgment: Option<SignalAck>,
}

/// An append-only log entry recording a session state transition.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionLogEntry {
    pub sequence: u64,
    pub recorded_at: String,
    pub session_id: String,
    pub transition: SessionTransition,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

/// Discriminated session state transitions for the audit log.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SessionTransition {
    SessionStarted {
        #[serde(default)]
        title: String,
        context: String,
    },
    SessionEnded,
    AgentJoined {
        agent_id: String,
        role: SessionRole,
        runtime: String,
    },
    AgentRemoved {
        agent_id: String,
    },
    AgentDisconnected {
        agent_id: String,
        reason: String,
    },
    AgentLeft {
        agent_id: String,
    },
    LivenessSynced {
        disconnected: Vec<String>,
        idled: Vec<String>,
    },
    RoleChanged {
        agent_id: String,
        from: SessionRole,
        to: SessionRole,
    },
    LeaderTransferRequested {
        from: String,
        to: String,
    },
    LeaderTransferConfirmed {
        from: String,
        to: String,
        confirmed_by: String,
    },
    LeaderTransferred {
        from: String,
        to: String,
    },
    TaskCreated {
        task_id: String,
        title: String,
        severity: TaskSeverity,
    },
    ObserveTaskCreated {
        task_id: String,
        title: String,
        severity: TaskSeverity,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        issue_id: Option<String>,
    },
    TaskAssigned {
        task_id: String,
        agent_id: String,
    },
    TaskQueued {
        task_id: String,
        agent_id: String,
    },
    TaskStatusChanged {
        task_id: String,
        from: TaskStatus,
        to: TaskStatus,
    },
    TaskCheckpointRecorded {
        task_id: String,
        checkpoint_id: String,
        progress: u8,
    },
    SignalSent {
        signal_id: String,
        agent_id: String,
        command: String,
    },
    SignalAcknowledged {
        signal_id: String,
        agent_id: String,
        result: AckResult,
    },
}
