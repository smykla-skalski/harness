use super::{run_task_board_orchestrator_once_db, should_sync_github_tasks};
use crate::daemon::db::AsyncDaemonDb;
use crate::feature_flags::TASK_BOARD_AUTOMATION_V2_ENV;
use crate::task_board::github::GitHubAutomation;
use crate::task_board::{
    GH_TOKEN_ENV, GITHUB_REPOSITORY_ENV, HARNESS_GITHUB_REPOSITORY_ENV, HARNESS_GITHUB_TOKEN_ENV,
    TaskBoardOrchestratorDispatchInput, TaskBoardOrchestratorRunOnceRequest,
    TaskBoardOrchestratorRunStatus, TaskBoardOrchestratorSettings, TaskBoardOrchestratorTickPhase,
    TaskBoardStatus,
};

/// The default settings already enable `SyncTaskBoard`, so this is the
/// configuration the tests below vary one field at a time from.
fn syncing_settings() -> TaskBoardOrchestratorSettings {
    let settings = TaskBoardOrchestratorSettings::default();
    assert!(
        settings
            .github_project
            .enabled_automations
            .enables(GitHubAutomation::SyncTaskBoard),
        "these tests assume the shipped default pulls; it no longer does"
    );
    settings
}

/// Neither reason to pull: the automation off and no inbox repository.
fn settings_without_a_source() -> TaskBoardOrchestratorSettings {
    let mut settings = TaskBoardOrchestratorSettings::default();
    settings
        .github_project
        .enabled_automations
        .enabled
        .retain(|automation| *automation != GitHubAutomation::SyncTaskBoard);
    settings.github_inbox.repositories.clear();
    settings
}

fn whole_board_run() -> TaskBoardOrchestratorDispatchInput {
    TaskBoardOrchestratorDispatchInput {
        item_id: None,
        status: Some(TaskBoardStatus::Todo),
        dry_run: false,
        project_dir: None,
        actor: None,
    }
}

#[test]
fn a_whole_board_run_pulls_from_github() {
    assert!(
        should_sync_github_tasks(&whole_board_run(), &syncing_settings()),
        "the case every other test varies from must sync, or they all pass vacuously"
    );
}

#[test]
fn an_unfiltered_run_pulls_from_github() {
    let mut input = whole_board_run();
    input.status = None;

    assert!(
        should_sync_github_tasks(&input, &syncing_settings()),
        "no lane filter means the whole board, which is what the pull fills"
    );
}

#[test]
fn an_item_scoped_run_skips_the_pull() {
    let mut input = whole_board_run();
    input.item_id = Some("task-1".to_string());

    assert!(
        !should_sync_github_tasks(&input, &syncing_settings()),
        "a run narrowed to one item must not drag the whole board through a sync"
    );
}

#[test]
fn a_run_scoped_to_another_lane_skips_the_pull() {
    let mut input = whole_board_run();
    input.status = Some(TaskBoardStatus::InProgress);

    assert!(
        !should_sync_github_tasks(&input, &syncing_settings()),
        "a lane the pull does not fill has nothing to sync for"
    );
}

#[test]
fn an_inbox_repository_syncs_without_the_automation_toggle() {
    let mut settings = settings_without_a_source();
    settings
        .github_inbox
        .repositories
        .push("owner/repo".to_string());

    assert!(
        should_sync_github_tasks(&whole_board_run(), &settings),
        "a configured inbox repository is its own reason to pull"
    );
}

#[test]
fn nothing_configured_means_nothing_to_pull() {
    assert!(
        !should_sync_github_tasks(&whole_board_run(), &settings_without_a_source()),
        "with the automation off and no inbox repository there is no source to sync from"
    );
}

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
