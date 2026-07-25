use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::project::TaskBoardProjectSource;
use crate::task_board::project_color::TaskBoardProjectColor;
use crate::task_board::project_shape::TaskBoardProjectShape;

use super::{ColorEdit, DisplayNameEdit, ProjectEdit};

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

/// Telling projects apart at a glance is the whole point, so registration has
/// to spend the palette before it repeats. This is the runtime half of what
/// the v52 backfill does for projects that were already there.
#[tokio::test]
async fn registration_hands_out_a_distinct_color_while_the_palette_has_room() {
    let (_directory, db) = database().await;
    let palette = TaskBoardProjectColor::PALETTE;

    for index in 0..palette.len() {
        db.ensure_task_board_project(TaskBoardProjectSource::Manual, &format!("project-{index}"))
            .await
            .expect("register project")
            .expect("names a project");
    }

    let mut colors: Vec<TaskBoardProjectColor> = db
        .list_task_board_projects()
        .await
        .expect("list")
        .iter()
        .map(|project| project.color)
        .collect();
    assert_eq!(colors.len(), palette.len());
    colors.sort_unstable_by_key(|color| color.as_str());
    colors.dedup();
    assert_eq!(
        colors.len(),
        palette.len(),
        "two projects were registered onto the same color with the palette not yet spent"
    );
}

/// A color is chosen once. Registering the next project must not disturb it,
/// or every card on the board changes color whenever a repository is added.
#[tokio::test]
async fn a_color_survives_a_later_registration() {
    let (_directory, db) = database().await;
    let first = db
        .ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/widgets")
        .await
        .expect("register project")
        .expect("names a project");
    let before = db
        .get_task_board_project(&first)
        .await
        .expect("read project")
        .expect("registered")
        .color;

    db.ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/gadgets")
        .await
        .expect("register second project");

    assert_eq!(
        db.get_task_board_project(&first)
            .await
            .expect("read project")
            .expect("registered")
            .color,
        before
    );
}

#[tokio::test]
async fn a_color_can_be_set_and_reset() {
    let (_directory, db) = database().await;
    let widgets = db
        .ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/widgets")
        .await
        .expect("register project")
        .expect("names a project");
    db.ensure_task_board_project(TaskBoardProjectSource::GitHub, "acme/gadgets")
        .await
        .expect("register second project");

    let chosen = db
        .update_task_board_project(
            &widgets,
            ProjectEdit {
                color: ColorEdit::Set(TaskBoardProjectColor::Graphite),
                ..ProjectEdit::default()
            },
        )
        .await
        .expect("set color");
    assert_eq!(chosen.color, TaskBoardProjectColor::Graphite);
    assert_eq!(chosen.slug, "acme/widgets", "the edit touched only the color");

    let reset = db
        .update_task_board_project(
            &widgets,
            ProjectEdit {
                color: ColorEdit::Reset,
                ..ProjectEdit::default()
            },
        )
        .await
        .expect("reset color");
    let sibling = db
        .list_task_board_projects()
        .await
        .expect("list")
        .into_iter()
        .find(|project| project.slug == "acme/gadgets")
        .expect("second project")
        .color;
    assert_ne!(
        reset.color,
        TaskBoardProjectColor::Graphite,
        "a reset that returns the chosen color is not a reset"
    );
    assert_ne!(
        reset.color, sibling,
        "a reset drops the project's own color from the tally but not the others'"
    );
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
        .update_task_board_project(
            &project_id,
            ProjectEdit {
                slug: Some("Acme/Gadgets"),
                ..ProjectEdit::default()
            },
        )
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
        .update_task_board_project(
            &project_id,
            ProjectEdit {
                display_name: DisplayNameEdit::Set("Widgets"),
                ..ProjectEdit::default()
            },
        )
        .await
        .expect("set display name");
    assert_eq!(named.label(), "Widgets");
    assert_eq!(named.slug, "acme/widgets");

    let cleared = db
        .update_task_board_project(
            &project_id,
            ProjectEdit {
                display_name: DisplayNameEdit::Clear,
                ..ProjectEdit::default()
            },
        )
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

    // The collision is a naming conflict, not a store failure, so retrying is
    // pointless and the code has to say so.
    let error = db
        .update_task_board_project(
            &widgets,
            ProjectEdit {
                slug: Some("acme/gadgets"),
                ..ProjectEdit::default()
            },
        )
        .await
        .expect_err("two projects of one source cannot share a slug");
    assert_eq!(error.code(), "USAGE", "{error}");
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
        .update_task_board_project(
            &project_id,
            ProjectEdit {
                slug: Some("not-a-repository"),
                ..ProjectEdit::default()
            },
        )
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
            ProjectEdit {
                display_name: DisplayNameEdit::Clear,
                ..ProjectEdit::default()
            },
        )
        .await
        .expect_err("an unknown project is refused");
    assert_eq!(error.code(), "USAGE", "{error}");
}

#[tokio::test]
async fn an_unreadable_shape_falls_back_to_the_organizations_own() {
    // An organization the fallback does not send to the default anyway,
    // otherwise this passes just as well against the collapse it exists to
    // catch.
    let organization = (0..64u32)
        .map(|index| format!("org{index}"))
        .find(|candidate| {
            TaskBoardProjectShape::derived(candidate) != TaskBoardProjectShape::DEFAULT
        })
        .expect("an organization whose derived shape is not the default");
    let (_directory, db) = database().await;
    let project = db
        .ensure_task_board_project(
            TaskBoardProjectSource::GitHub,
            &format!("{organization}/widgets"),
        )
        .await
        .expect("register project")
        .expect("names a project");

    // Passes the column's CHECK, so this is the shape of a board written by a
    // build that knew a shape this one has since retired.
    sqlx::query("UPDATE task_board_projects SET shape = ?2 WHERE project_id = ?1")
        .bind(&project)
        .bind("octagon")
        .execute(db.pool())
        .await
        .expect("store a shape this build cannot read");

    let read = db
        .get_task_board_project(&project)
        .await
        .expect("read project")
        .expect("the project is still there");

    assert_eq!(
        read.shape,
        TaskBoardProjectShape::derived(&organization),
        "an unreadable shape collapsed onto the default and took the second channel with it"
    );
}
