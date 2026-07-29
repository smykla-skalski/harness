use chrono::Utc;
use std::sync::{Arc, OnceLock};

use super::*;
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::service::task_board_orchestrator_status_db;
use crate::feature_flags::TASK_BOARD_AUTOMATION_V2_ENV;
use crate::task_board::{
    TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode, TaskBoardOrchestratorState,
};

async fn database() -> AsyncDaemonDb {
    let temp = tempfile::tempdir().expect("tempdir");
    AsyncDaemonDb::connect(&temp.keep().join("harness.db"))
        .await
        .expect("open database")
}

#[tokio::test]
async fn first_durable_status_after_startup_has_an_initialized_control() {
    temp_env::async_with_vars([(TASK_BOARD_AUTOMATION_V2_ENV, Some("1"))], async {
        let db = Arc::new(database().await);
        db.replace_task_board_orchestrator_state(&TaskBoardOrchestratorState {
            enabled: true,
            running: true,
            ..TaskBoardOrchestratorState::default()
        })
        .await
        .expect("save running legacy intent");

        let async_db_slot = Arc::new(OnceLock::new());
        assert!(
            async_db_slot.set(Arc::clone(&db)).is_ok(),
            "publish test database"
        );
        initialize_control_before_serving(&async_db_slot)
            .await
            .expect("initialize startup control");
        let control_before_status = db
            .task_board_automation_control()
            .await
            .expect("load startup control");

        let status = task_board_orchestrator_status_db(&db)
            .await
            .expect("read first durable status");
        let automation = status.automation.expect("durable automation status");
        assert_eq!(
            automation.desired_mode,
            TaskBoardAutomationDesiredMode::Continuous
        );
        assert_eq!(
            automation.admission_state,
            TaskBoardAutomationAdmissionState::Accepting
        );
        assert_eq!(
            db.task_board_automation_control()
                .await
                .expect("reload startup control"),
            control_before_status
        );
        assert!(
            automation
                .observed_at
                .parse::<chrono::DateTime<Utc>>()
                .is_ok()
        );
    })
    .await;
}
