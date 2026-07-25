use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, ColorEdit, DisplayNameEdit, ProjectEdit};
use crate::daemon::protocol::{
    TaskBoardCreateItemRequest, TaskBoardProjectUpdateRequest, TaskBoardUpdateIdentityClears,
    TaskBoardUpdateItemRequest,
};
use crate::task_board::project::TaskBoardProjectSource;
use crate::task_board::project_color::TaskBoardProjectColor;

use super::{create_task_board_item_db, update_task_board_item_db, update_task_board_project_db};

/// Moving an item to another project has to re-resolve its attribution.
/// `resolve_item_project_in_tx` treats an assigned project as settled, so a
/// stale one survives every later write and the card keeps naming the project
/// the item left.
#[tokio::test]
async fn moving_an_item_re_resolves_its_project() {
    let directory = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
        .await
        .expect("database");
    let create: TaskBoardCreateItemRequest = serde_json::from_value(serde_json::json!({
        "title": "Move me",
        "project_id": "acme/widgets",
    }))
    .expect("create request");

    let created = create_task_board_item_db(&db, &create)
        .await
        .expect("create item");
    let first = created
        .source_project_id
        .clone()
        .expect("attributed on create");

    let moved = update_task_board_item_db(
        &db,
        &created.id,
        &TaskBoardUpdateItemRequest {
            project_id: Some("acme/gadgets".to_string()),
            ..Default::default()
        },
    )
    .await
    .expect("move the item");
    let second = moved
        .source_project_id
        .clone()
        .expect("attributed after the move");
    assert_ne!(second, first, "the item kept the project it left");

    let cleared = update_task_board_item_db(
        &db,
        &created.id,
        &TaskBoardUpdateItemRequest {
            clear_identity: TaskBoardUpdateIdentityClears {
                clear_project_id: true,
                ..Default::default()
            },
            ..Default::default()
        },
    )
    .await
    .expect("clear the project");
    assert_eq!(cleared.source_project_id, None);
}

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
    db.update_task_board_project(
        &project_id,
        ProjectEdit {
            display_name: DisplayNameEdit::Set("Widgets"),
            ..ProjectEdit::default()
        },
    )
    .await
    .expect("set display name");

    let error = update_task_board_project_db(
        &db,
        &TaskBoardProjectUpdateRequest {
            project_id: project_id.clone(),
            slug: None,
            display_name: Some("Gadgets".to_string()),
            clear_display_name: true,
            ..TaskBoardProjectUpdateRequest::default()
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

/// The color has the same two-sided edit and needs the same answer. Refusing
/// one field and silently picking a winner on the other is the sort of gap the
/// display-name case only closed for itself.
#[tokio::test]
async fn setting_and_resetting_a_color_together_is_refused() {
    let directory = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
        .await
        .expect("database");
    let project_id = db
        .ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/widgets")
        .await
        .expect("register project")
        .expect("names a project");
    db.update_task_board_project(
        &project_id,
        ProjectEdit {
            color: ColorEdit::Set(TaskBoardProjectColor::Graphite),
            ..ProjectEdit::default()
        },
    )
    .await
    .expect("set color");

    let error = update_task_board_project_db(
        &db,
        &TaskBoardProjectUpdateRequest {
            project_id: project_id.clone(),
            color: Some(TaskBoardProjectColor::Pink),
            reset_color: true,
            ..TaskBoardProjectUpdateRequest::default()
        },
    )
    .await
    .expect_err("conflicting color edit is refused");
    assert_eq!(error.code(), "USAGE", "{error}");
    assert!(
        error.message().contains("set and reset"),
        "unexpected message: {error}"
    );

    let stored = db
        .get_task_board_project(&project_id)
        .await
        .expect("read project")
        .expect("project still registered");
    assert_eq!(
        stored.color,
        TaskBoardProjectColor::Graphite,
        "a refused edit must leave the stored color alone"
    );
}
