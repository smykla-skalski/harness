use super::{github_discovery_request, prepare_run, run_dispatch_phase, should_sync_github_tasks};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::TaskBoardOrchestratorRunOnceRequest;
use crate::task_board::github::GitHubAutomation;
use crate::task_board::{
    ExternalSyncDirection, TaskBoardAutomationDesiredMode, TaskBoardAutomationRunOutcome,
    TaskBoardAutomationRunTrigger, TaskBoardAutomationScope, TaskBoardOrchestratorDispatchInput,
    TaskBoardOrchestratorSettings, TaskBoardStatus,
};
use crate::daemon::db::task_board::prelude::*;

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
fn a_run_scoped_to_another_lane_still_pulls() {
    let mut input = whole_board_run();
    input.status = Some(TaskBoardStatus::InProgress);

    assert!(
        should_sync_github_tasks(&input, &syncing_settings()),
        "discovery is independent of dispatch status: a lane-scoped run must still fill the Inbox"
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

#[test]
fn discovery_pulls_every_status_not_the_dispatch_lane() {
    let request = github_discovery_request(false);

    assert_eq!(
        request.status, None,
        "discovery must import every eligible pull request, not only the dispatched lane"
    );
    assert!(matches!(request.direction, ExternalSyncDirection::Pull));
    assert!(!request.dry_run);
    assert!(github_discovery_request(true).dry_run);
}

#[tokio::test]
async fn a_run_dispatches_only_items_present_when_it_was_prepared() {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open database");
    let settings = settings_without_a_source();
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("save settings");
    db.create_task_board_item(crate::task_board::TaskBoardItem::new(
        "present-at-prepare".into(),
        "Present at prepare".into(),
        "The run owns this candidate".into(),
        "2026-08-02T10:00:00Z".into(),
    ))
    .await
    .expect("create initial item");
    let request = TaskBoardOrchestratorRunOnceRequest {
        status: Some(TaskBoardStatus::Todo),
        dry_run: Some(true),
        ..TaskBoardOrchestratorRunOnceRequest::default()
    };
    let prepared = prepare_run(&db, &request, &settings, None)
        .await
        .expect("prepare run");

    db.create_task_board_item(crate::task_board::TaskBoardItem::new(
        "arrived-after-prepare".into(),
        "Arrived after prepare".into(),
        "A sync can discover this, but the current run must not own it".into(),
        "2026-08-02T10:00:01Z".into(),
    ))
    .await
    .expect("create later item");

    let (_, dispatch) = run_dispatch_phase(&db, &settings, &prepared, None)
        .await
        .expect("preview dispatch");
    let planned_ids = dispatch
        .plans
        .iter()
        .map(|plan| plan.board_item_id.as_str())
        .collect::<Vec<_>>();

    assert_eq!(planned_ids, ["present-at-prepare"]);
}

#[tokio::test]
async fn stop_fences_dispatch_before_another_item_can_start() {
    let temp = tempfile::tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&temp.path().join("harness.db"))
        .await
        .expect("open database");
    db.start_task_board_automation(
        TaskBoardAutomationDesiredMode::Continuous,
        chrono::Utc::now(),
    )
    .await
    .expect("start automation");
    let start = super::super::TaskBoardAutomationRunSession::acquire(
        &db,
        TaskBoardAutomationRunTrigger::Manual,
        Some("operator".into()),
        false,
        TaskBoardAutomationScope::default(),
    )
    .await
    .expect("acquire run");
    let super::super::TaskBoardAutomationRunStart::Acquired(session) = start else {
        panic!("manual run should be acquired");
    };
    let settings = settings_without_a_source();
    db.create_task_board_item(crate::task_board::TaskBoardItem::new(
        "stop-fenced-item".into(),
        "Stop-fenced item".into(),
        "This item must not start after Stop".into(),
        "2026-08-02T10:05:00Z".into(),
    ))
    .await
    .expect("create item");
    let prepared = prepare_run(
        &db,
        &TaskBoardOrchestratorRunOnceRequest {
            status: Some(TaskBoardStatus::Todo),
            dry_run: Some(false),
            ..TaskBoardOrchestratorRunOnceRequest::default()
        },
        &settings,
        Some(session.run_id()),
    )
    .await
    .expect("prepare run");

    db.stop_task_board_automation(chrono::Utc::now())
        .await
        .expect("stop automation");
    let error = run_dispatch_phase(&db, &settings, &prepared, Some(&session))
        .await
        .expect_err("Stop must fence dispatch");

    assert_eq!(error.code(), "KSRCLI092");
    let item = db
        .task_board_item("stop-fenced-item")
        .await
        .expect("load item");
    assert_eq!(item.status, TaskBoardStatus::Todo);
    let outcome = session
        .finalize(TaskBoardAutomationRunOutcome::Failed, Some(&error))
        .await
        .expect("finalize cancelled run");
    assert_eq!(outcome, TaskBoardAutomationRunOutcome::Cancelled);
}
