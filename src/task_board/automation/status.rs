use serde::{Deserialize, Serialize};

use crate::task_board::{ExternalRefProvider, TaskBoardStatus};

pub const TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION: u32 = 1;

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

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAutomationHistoryRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub limit: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
}

impl TaskBoardAutomationHistoryRequest {
    #[must_use]
    pub fn normalized_limit(&self) -> u32 {
        self.limit.unwrap_or(100).clamp(1, 500)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAutomationHistoryResponse {
    pub runs: Vec<TaskBoardAutomationRunInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_cursor: Option<String>,
    pub has_older: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskBoardAutomationRunStage {
    pub sequence: u64,
    pub stage: String,
    pub state: String,
    pub recorded_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub payload: Option<serde_json::Value>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TaskBoardAutomationRunDetail {
    pub run: TaskBoardAutomationRunInfo,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub stages: Vec<TaskBoardAutomationRunStage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAutomationMetrics {
    pub runs_total: u64,
    pub runs_running: u64,
    pub runs_completed: u64,
    pub runs_noop: u64,
    pub runs_partial: u64,
    pub runs_failed: u64,
    pub runs_cancelled: u64,
    pub open_conflicts: u64,
    pub captured_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardAutomationSnapshot {
    #[serde(default = "default_snapshot_schema_version")]
    pub schema_version: u32,
    pub revision: u64,
    pub desired_mode: TaskBoardAutomationDesiredMode,
    pub admission_state: TaskBoardAutomationAdmissionState,
    pub effective_state: TaskBoardAutomationEffectiveState,
    pub observed_at: String,
    pub heartbeat_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub heartbeat_age_seconds: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_run_at: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_retry_at: Option<String>,
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

const fn default_snapshot_schema_version() -> u32 {
    TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION
}

#[cfg(test)]
mod tests {
    use super::{TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION, TaskBoardAutomationHistoryRequest};

    #[test]
    fn history_limit_is_bounded() {
        assert_eq!(
            TaskBoardAutomationHistoryRequest::default().normalized_limit(),
            100
        );
        assert_eq!(
            TaskBoardAutomationHistoryRequest {
                limit: Some(0),
                before: None,
            }
            .normalized_limit(),
            1
        );
        assert_eq!(
            TaskBoardAutomationHistoryRequest {
                limit: Some(900),
                before: None,
            }
            .normalized_limit(),
            500
        );
    }

    #[test]
    fn compact_snapshot_schema_starts_at_one() {
        assert_eq!(TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION, 1);
        assert_eq!(super::default_snapshot_schema_version(), 1);
    }
}
