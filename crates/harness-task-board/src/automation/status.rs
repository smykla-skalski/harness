//! Task-board automation runtime snapshot.
//!
//! Relocated to `harness_protocol::daemon::task_board::automation_snapshot`
//! (#1145): pure data plus pure inherent methods, needed there because
//! `TaskBoardOrchestratorStatus` embeds `TaskBoardAutomationSnapshot`
//! directly. Re-exported here unchanged so every existing caller keeps
//! resolving `crate::{TaskBoardAutomationSnapshot, ...}` (this module is
//! private; `automation.rs`'s own `pub use status::*;` carries the names
//! forward the same way it always has).
pub use harness_protocol::daemon::task_board::automation_snapshot::{
    TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION, TaskBoardAutomationAdmissionState,
    TaskBoardAutomationCancelTarget, TaskBoardAutomationDesiredMode,
    TaskBoardAutomationEffectiveState, TaskBoardAutomationHistoryRequest,
    TaskBoardAutomationHistoryResponse, TaskBoardAutomationMetrics, TaskBoardAutomationQueueSummary,
    TaskBoardAutomationRunDetail, TaskBoardAutomationRunInfo, TaskBoardAutomationRunOutcome,
    TaskBoardAutomationRunStage, TaskBoardAutomationRunState, TaskBoardAutomationRunTrigger,
    TaskBoardAutomationScope, TaskBoardAutomationSnapshot,
};

#[cfg(test)]
mod tests {
    use super::{
        TASK_BOARD_AUTOMATION_SNAPSHOT_SCHEMA_VERSION, TaskBoardAutomationHistoryRequest,
        TaskBoardAutomationSnapshot,
    };

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
    }

    #[test]
    fn legacy_snapshot_without_schema_version_stays_at_version_one() {
        let snapshot: TaskBoardAutomationSnapshot = serde_json::from_value(serde_json::json!({
            "revision": 4,
            "desired_mode": "off",
            "admission_state": "stopped",
            "effective_state": "idle",
            "observed_at": "2026-07-17T00:00:00Z",
            "heartbeat_at": "2026-07-17T00:00:00Z",
            "settings_revision": 2,
            "policy_revision": 3,
            "queue": {
                "ready": 0,
                "awaiting_approval": 0,
                "policy_blocked": 0,
                "preparing": 0,
                "retrying": 0,
                "starting": 0,
                "active": 0,
                "draining": 0,
                "cleanup_required": 0
            }
        }))
        .expect("decode legacy compact snapshot");

        assert_eq!(snapshot.schema_version, 1);
        assert!(snapshot.cancelable_targets.is_empty());
        assert!(!snapshot.cancelable_targets_truncated);
    }
}
