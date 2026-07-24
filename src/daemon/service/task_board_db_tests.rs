use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, DisplayNameEdit};
use crate::daemon::protocol::TaskBoardProjectUpdateRequest;
use crate::task_board::project::TaskBoardProjectSource;

use super::update_task_board_project_db;

/// Setting and clearing in one request is a caller bug, not a precedence
/// question. Whichever side won silently, the other half of the request was
/// dropped while the call still reported success.
#[tokio::test]
async fn setting_and_clearing_a_display_name_together_is_refused() {
    let directory = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
        .await
        .expect("database");
    let project_id = db
        .ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/widgets")
        .await
        .expect("register project")
        .expect("names a project");
    db.update_task_board_project(&project_id, None, DisplayNameEdit::Set("Widgets"))
        .await
        .expect("set display name");

    let error = update_task_board_project_db(
        &db,
        &TaskBoardProjectUpdateRequest {
            project_id: project_id.clone(),
            slug: None,
            display_name: Some("Gadgets".to_string()),
            clear_display_name: true,
        },
    )
    .await
    .expect_err("conflicting display name edit is refused");
    assert!(
        error.message().contains("set and clear"),
        "unexpected message: {error}"
    );

    let projects = db.list_task_board_projects().await.expect("list projects");
    let stored = projects
        .iter()
        .find(|project| project.project_id == project_id)
        .expect("project still registered");
    assert_eq!(
        stored.display_name.as_deref(),
        Some("Widgets"),
        "a refused edit must leave the stored name alone"
    );
}
