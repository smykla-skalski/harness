use serde::{Deserialize, Serialize};

pub use crate::task_board::{
    TaskBoardAutomationCancelTarget, TaskBoardAutomationHistoryRequest,
    TaskBoardAutomationHistoryResponse, TaskBoardAutomationMetrics, TaskBoardAutomationRunDetail,
    TaskBoardAutomationSnapshot,
};

pub type TaskBoardAutomationRunsResponse = TaskBoardAutomationHistoryResponse;
pub type TaskBoardAutomationRunDetailResponse = TaskBoardAutomationRunDetail;
pub type TaskBoardAutomationMetricsResponse = TaskBoardAutomationMetrics;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TaskBoardAutomationRunDetailRequest {
    pub run_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TaskBoardAutomationForceCancelRequest {
    pub target: TaskBoardAutomationCancelTarget,
    pub reason: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub actor: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAutomationForceCancelDisposition {
    AcceptedPending,
    Cancelled,
    ReplayedPending,
    ReplayedCancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TaskBoardAutomationForceCancelResponse {
    pub disposition: TaskBoardAutomationForceCancelDisposition,
}

#[cfg(test)]
mod tests {
    use crate::daemon::protocol::TaskBoardUpdatedPayload;

    #[test]
    fn legacy_task_board_push_payload_defaults_snapshot_to_none() {
        let payload: TaskBoardUpdatedPayload = serde_json::from_value(serde_json::json!({
            "revision": 7,
            "scopes": ["task_board:items"]
        }))
        .expect("decode legacy task-board push payload");

        assert!(payload.automation.is_none());
        let encoded = serde_json::to_value(payload).expect("encode feature-off push payload");
        assert!(encoded.get("automation").is_none());
    }
}
