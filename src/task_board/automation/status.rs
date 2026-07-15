use serde::{Deserialize, Serialize};

use crate::task_board::{ExternalRefProvider, TaskBoardStatus};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAutomationDesiredMode {
    #[default]
    Off,
    Continuous,
    Step,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAutomationAdmissionState {
    Accepting,
    Draining,
    #[default]
    Stopped,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAutomationEffectiveState {
    Offline,
    #[default]
    Idle,
    Scheduled,
    Running,
    BackingOff,
    Stopping,
    Degraded,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAutomationRunTrigger {
    Scheduled,
    Event,
    Manual,
    Recovery,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAutomationRunState {
    Running,
    Cancelling,
    Terminal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAutomationRunOutcome {
    Completed,
    Noop,
    Partial,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAutomationScope {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider: Option<ExternalRefProvider>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provider_scope: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<TaskBoardStatus>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAutomationQueueSummary {
    pub ready: usize,
    pub awaiting_approval: usize,
    pub policy_blocked: usize,
    pub preparing: usize,
    pub retrying: usize,
    pub starting: usize,
    pub active: usize,
    pub draining: usize,
    pub cleanup_required: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAutomationRunInfo {
    pub run_id: String,
    pub trigger: TaskBoardAutomationRunTrigger,
    pub state: TaskBoardAutomationRunState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub outcome: Option<TaskBoardAutomationRunOutcome>,
    pub dry_run: bool,
    pub scope: TaskBoardAutomationScope,
    pub started_at: String,
    pub heartbeat_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAutomationSnapshot {
    pub revision: u64,
    pub desired_mode: TaskBoardAutomationDesiredMode,
    pub admission_state: TaskBoardAutomationAdmissionState,
    pub effective_state: TaskBoardAutomationEffectiveState,
    pub observed_at: String,
    pub heartbeat_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_run_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_success_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_reconciliation_at: Option<String>,
    pub settings_revision: u64,
    pub policy_revision: u64,
    pub queue: TaskBoardAutomationQueueSummary,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_run: Option<TaskBoardAutomationRunInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked_reason: Option<String>,
}
