use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::project::TaskBoardProjectSource;

use super::DisplayNameEdit;

async fn database() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
        .await
        .expect("database");
    (directory, db)
}

#[tokio::test]
async fn registering_the_same_repository_twice_yields_one_project() {
    let (_directory, db) = database().await;

    let first = db
        .ensure_task_board_project(TaskBoardProjectSource::GitHub, "Acme/Widgets")
        .await
        .expect("register project")
        .expect("repository names a project");
    let second = db
        .ensure_task_board_project(TaskBoardProjectSource::GitHub, " acme/widgets ")
        .await
        .expect("register project again")
        .expect("repository names a project");

    assert_eq!(first, second, "case and padding do not fork the identity");
    assert_eq!(db.list_task_board_projects().await.expect("list").len(), 1);
}

#[tokio::test]
async fn the_same_slug_under_two_sources_is_two_projects() {
    let (_directory, db) = database().await;

    let github = db
        .ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/widgets")
        .await
        .expect("register github project")
        .expect("names a project");
    let manual = db
        .ensure_task_board_project(TaskBoardProjectSource::Manual, "acme/widgets")
        .await
        .expect("register manual project")
        .expect("names a project");

    assert_ne!(github, manual);
}

#[tokio::test]
async fn a_value_that_cannot_name_a_project_registers_nothing() {
    let (_directory, db) = database().await;

    assert_eq!(
        db.ensure_task_board_project(TaskBoardProjectSource::GitHub, "not-a-repository")
            .await
            .expect("attempt registration"),
        None
    );
    assert_eq!(
        db.ensure_task_board_project(TaskBoardProjectSource::Manual, "   ")
            .await
            .expect("attempt registration"),
        None
    );
    assert!(db.list_task_board_projects().await.expect("list").is_empty());
}

#[tokio::test]
async fn concurrent_registration_converges_on_one_identity() {
    let (_directory, db) = database().await;
    let first_db = db.clone();
    let second_db = db.clone();

    let (first, second) = tokio::join!(
        first_db.ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/widgets"),
        second_db.ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/widgets"),
    );

    assert_eq!(
        first.expect("first registration"),
        second.expect("second registration")
    );
    assert_eq!(db.list_task_board_projects().await.expect("list").len(), 1);
}

#[tokio::test]
async fn renaming_keeps_the_identifier_and_normalizes_the_new_slug() {
    let (_directory, db) = database().await;
    let project_id = db
        .ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/widgets")
        .await
        .expect("register project")
        .expect("names a project");

    let renamed = db
        .update_task_board_project(&project_id, Some("Acme/Gadgets"), DisplayNameEdit::Keep)
        .await
        .expect("rename project");

    assert_eq!(renamed.project_id, project_id);
    assert_eq!(renamed.slug, "acme/gadgets");
    assert_eq!(
        db.ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/gadgets")
            .await
            .expect("resolve renamed project"),
        Some(project_id),
        "the new slug resolves back to the original project"
    );
}

#[tokio::test]
async fn a_display_name_can_be_set_and_cleared_without_touching_the_slug() {
    let (_directory, db) = database().await;
    let project_id = db
        .ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/widgets")
        .await
        .expect("register project")
        .expect("names a project");

    let named = db
        .update_task_board_project(&project_id, None, DisplayNameEdit::Set("Widgets"))
        .await
        .expect("set display name");
    assert_eq!(named.label(), "Widgets");
    assert_eq!(named.slug, "acme/widgets");

    let cleared = db
        .update_task_board_project(&project_id, None, DisplayNameEdit::Clear)
        .await
        .expect("clear display name");
    assert_eq!(cleared.display_name, None);
    assert_eq!(cleared.label(), "acme/widgets");
}

#[tokio::test]
async fn renaming_onto_an_existing_slug_is_refused() {
    let (_directory, db) = database().await;
    let widgets = db
        .ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/widgets")
        .await
        .expect("register project")
        .expect("names a project");
    db.ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/gadgets")
        .await
        .expect("register second project");

    assert!(
        db.update_task_board_project(&widgets, Some("acme/gadgets"), DisplayNameEdit::Keep)
            .await
            .is_err(),
        "two projects of one source cannot share a slug"
    );
}

#[tokio::test]
async fn renaming_to_an_unusable_slug_is_refused() {
    let (_directory, db) = database().await;
    let project_id = db
        .ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/widgets")
        .await
        .expect("register project")
        .expect("names a project");

    // The caller named the slug wrong; an IO code would tell them to retry.
    let error = db
        .update_task_board_project(&project_id, Some("not-a-repository"), DisplayNameEdit::Keep)
        .await
        .expect_err("an unusable slug is refused");
    assert_eq!(error.code(), "USAGE", "{error}");
}

#[tokio::test]
async fn renaming_an_unregistered_project_is_a_usage_error() {
    let (_directory, db) = database().await;

    let error = db
        .update_task_board_project(
            "project-00000000000000000000000000000000",
            None,
            DisplayNameEdit::Clear,
        )
        .await
        .expect_err("an unknown project is refused");
    assert_eq!(error.code(), "USAGE", "{error}");
}
