use serde::{Deserialize, Serialize};

pub use crate::task_board::{
    TaskBoardAutomationHistoryRequest, TaskBoardAutomationHistoryResponse,
    TaskBoardAutomationMetrics, TaskBoardAutomationRunDetail, TaskBoardAutomationSnapshot,
};

pub type TaskBoardAutomationRunsResponse = TaskBoardAutomationHistoryResponse;
pub type TaskBoardAutomationRunDetailResponse = TaskBoardAutomationRunDetail;
pub type TaskBoardAutomationMetricsResponse = TaskBoardAutomationMetrics;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TaskBoardAutomationRunDetailRequest {
    pub run_id: String,
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
    }
}
