use serde::{Deserialize, Serialize};

use crate::task_board::{
    TaskBoardExecutionPhase, TaskBoardPhaseCapabilityProfile, TaskBoardWorkflowSnapshot,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardRemoteAssignmentState {
    Offered,
    Claimed,
    Started,
    Running,
    Completed,
    Failed,
    Cancelled,
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardRemoteExecutionRequest {
    pub assignment_id: String,
    pub execution_id: String,
    pub item_id: String,
    pub phase: TaskBoardExecutionPhase,
    pub idempotency_key: String,
    pub fencing_epoch: u64,
    pub repository: String,
    pub workflow: TaskBoardWorkflowSnapshot,
    pub capabilities: TaskBoardPhaseCapabilityProfile,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardRemoteExecutionClaim {
    pub assignment_id: String,
    pub host_id: String,
    pub fencing_epoch: u64,
    pub accepted: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardRemoteExecutionStatus {
    pub assignment_id: String,
    pub host_id: String,
    pub fencing_epoch: u64,
    pub state: TaskBoardRemoteAssignmentState,
    pub heartbeat_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskBoardRemoteExecutionResult {
    pub assignment_id: String,
    pub host_id: String,
    pub fencing_epoch: u64,
    pub state: TaskBoardRemoteAssignmentState,
    pub result: serde_json::Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardExecutionHostAdvertisement {
    pub host_id: String,
    pub protocol_version: u32,
    pub repositories: Vec<String>,
    pub runtimes: Vec<String>,
    pub capabilities: Vec<TaskBoardPhaseCapabilityProfile>,
    pub capacity: u32,
    pub active_assignments: u32,
    pub heartbeat_at: String,
}
