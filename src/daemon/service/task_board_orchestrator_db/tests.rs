use super::*;

use crate::feature_flags::TASK_BOARD_AUTOMATION_V2_ENV;
use crate::task_board::{
    GH_TOKEN_ENV, GITHUB_REPOSITORY_ENV, HARNESS_GITHUB_REPOSITORY_ENV, HARNESS_GITHUB_TOKEN_ENV,
};

#[tokio::test]
async fn dry_run_exercises_the_shipped_runner_without_external_credentials() {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open database");

    temp_env::async_with_vars(
        [
            (TASK_BOARD_AUTOMATION_V2_ENV, Some("0")),
            (HARNESS_GITHUB_TOKEN_ENV, None),
            (GH_TOKEN_ENV, None),
            (HARNESS_GITHUB_REPOSITORY_ENV, None),
            (GITHUB_REPOSITORY_ENV, None),
        ],
        async {
            let status = run_task_board_orchestrator_once_db(
                &db,
                &TaskBoardOrchestratorRunOnceRequest {
                    dry_run: Some(true),
                    ..TaskBoardOrchestratorRunOnceRequest::default()
                },
            )
            .await
            .expect("run shipped orchestrator");

            let last_run = status.last_run.expect("persisted run summary");
            assert_eq!(last_run.status, TaskBoardOrchestratorRunStatus::Completed);
            assert!(last_run.dry_run);
            assert!(last_run.dispatch.is_some());
            assert!(last_run.evaluation.is_some());
            assert_eq!(
                status.current_tick.map(|tick| tick.phase),
                Some(TaskBoardOrchestratorTickPhase::Completed)
            );
        },
    )
    .await;
}
