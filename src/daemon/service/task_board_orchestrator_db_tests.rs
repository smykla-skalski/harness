use super::should_sync_github_tasks;
use crate::task_board::github::GitHubAutomation;
use crate::task_board::{
    TaskBoardOrchestratorDispatchInput, TaskBoardOrchestratorSettings, TaskBoardStatus,
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
