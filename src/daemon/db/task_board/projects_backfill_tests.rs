use sqlx::{query, query_scalar};
use tempfile::{TempDir, tempdir};

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::project::is_project_id;
use crate::task_board::{ExternalRef, ExternalRefProvider, TaskBoardItem};

/// The state a build whose rules could not name a repository leaves the board
/// in: no item holds a project, and none is registered either. Every row goes
/// at once because an item still pointing at a project pins it through the
/// foreign key.
async fn strip_attribution(db: &AsyncDaemonDb) {
    query("UPDATE task_board_items SET source_project_id = NULL")
        .execute(db.pool())
        .await
        .expect("strip every item's attribution");
    query("DELETE FROM task_board_projects")
        .execute(db.pool())
        .await
        .expect("forget the projects that attribution registered");
}

async fn stored_project_id(db: &AsyncDaemonDb, item_id: &str) -> Option<String> {
    query_scalar::<_, Option<String>>(
        "SELECT source_project_id FROM task_board_items WHERE item_id = ?1",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("read the item's attribution")
}

#[tokio::test]
async fn an_item_left_without_a_project_is_attributed_and_its_repository_registered() {
    let (_dir, db) = connect().await;
    let mut item = item("task-orphan");
    item.execution_repository = Some("Acme/Widgets".into());
    db.create_task_board_item(item).await.expect("create item");
    strip_attribution(&db).await;

    assert_eq!(
        db.reattribute_unattributed_task_board_items()
            .await
            .expect("reattribute"),
        1
    );

    let attributed = stored_project_id(&db, "task-orphan")
        .await
        .expect("the item holds a project");
    assert!(is_project_id(&attributed), "{attributed}");
    let projects = db.list_task_board_projects().await.expect("list projects");
    assert_eq!(projects.len(), 1, "the repository is missing from the list");
    assert_eq!(projects[0].slug, "acme/widgets");
    assert_eq!(projects[0].project_id, attributed);
}

/// The rows this repairs were stored by a build whose rules were narrower, so
/// the pass has to read the ref the same way a write does or it repairs
/// everything except the case that motivated it.
#[tokio::test]
async fn an_item_named_only_by_its_external_ref_is_attributed() {
    let (_dir, db) = connect().await;
    let mut item = item("task-review");
    item.external_refs.push(ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "Acme/Widgets#97".into(),
        url: Some("https://github.com/Acme/Widgets/pull/97".into()),
        sync_state: None,
    });
    db.create_task_board_item(item).await.expect("create item");
    strip_attribution(&db).await;

    assert_eq!(
        db.reattribute_unattributed_task_board_items()
            .await
            .expect("reattribute"),
        1
    );

    assert!(stored_project_id(&db, "task-review").await.is_some());
    assert_eq!(
        db.list_task_board_projects().await.expect("list projects")[0].slug,
        "acme/widgets"
    );
}

#[tokio::test]
async fn an_item_nothing_names_stays_unattributed() {
    let (_dir, db) = connect().await;
    db.create_task_board_item(item("task-bare"))
        .await
        .expect("create item");

    assert_eq!(
        db.reattribute_unattributed_task_board_items()
            .await
            .expect("reattribute"),
        0
    );

    assert_eq!(stored_project_id(&db, "task-bare").await, None);
    assert!(
        db.list_task_board_projects()
            .await
            .expect("list projects")
            .is_empty(),
        "an unknown origin invented a project"
    );
}

/// Two projects can share a colour only by racing for it, so a repair pass that
/// re-registered an item's project would hand the board a second identity for
/// one repository and recolour every card attached to the first.
#[tokio::test]
async fn an_attributed_item_is_left_exactly_as_it_is() {
    let (_dir, db) = connect().await;
    let mut item = item("task-settled");
    item.execution_repository = Some("acme/widgets".into());
    db.create_task_board_item(item).await.expect("create item");
    let before = stored_project_id(&db, "task-settled")
        .await
        .expect("the create path attributed it");

    assert_eq!(
        db.reattribute_unattributed_task_board_items()
            .await
            .expect("reattribute"),
        0
    );

    assert_eq!(stored_project_id(&db, "task-settled").await, Some(before));
    assert_eq!(db.list_task_board_projects().await.expect("list").len(), 1);
}

/// Nothing renders a tombstone, so attributing one would register a repository
/// on the strength of work that no longer exists.
#[tokio::test]
async fn a_deleted_item_is_not_attributed() {
    let (_dir, db) = connect().await;
    let mut item = item("task-gone");
    item.execution_repository = Some("acme/widgets".into());
    db.create_task_board_item(item).await.expect("create item");
    db.delete_task_board_item("task-gone")
        .await
        .expect("delete item");
    strip_attribution(&db).await;

    assert_eq!(
        db.reattribute_unattributed_task_board_items()
            .await
            .expect("reattribute"),
        0
    );

    assert_eq!(stored_project_id(&db, "task-gone").await, None);
    assert!(db.list_task_board_projects().await.expect("list").is_empty());
}

/// Attribution is derived metadata, not an edit. Bumping the revision would
/// make every board client refetch on a boot that changed nothing they can see,
/// and moving `updated_at` would reorder a lane sorted by it.
#[tokio::test]
async fn attributing_an_item_is_not_an_edit_to_it() {
    let (_dir, db) = connect().await;
    let mut item = item("task-untouched");
    item.execution_repository = Some("acme/widgets".into());
    db.create_task_board_item(item).await.expect("create item");
    strip_attribution(&db).await;
    let before = revision_and_updated_at(&db, "task-untouched").await;

    db.reattribute_unattributed_task_board_items()
        .await
        .expect("reattribute");

    assert_eq!(revision_and_updated_at(&db, "task-untouched").await, before);
}

/// A row this build cannot decode is the state the pass found it in. Failing
/// over it would cost the daemon its boot to repair a colour mark, and would
/// take every readable item's mark down with it.
#[tokio::test]
async fn an_unreadable_row_does_not_stop_the_pass() {
    let (_dir, db) = connect().await;
    for id in ["task-broken", "task-fine"] {
        let mut item = item(id);
        item.execution_repository = Some("acme/widgets".into());
        db.create_task_board_item(item).await.expect("create item");
    }
    strip_attribution(&db).await;
    query("UPDATE task_board_items SET tags_json = 'not json' WHERE item_id = ?1")
        .bind("task-broken")
        .execute(db.pool())
        .await
        .expect("store a row this build cannot decode");

    assert_eq!(
        db.reattribute_unattributed_task_board_items()
            .await
            .expect("an unreadable row is skipped, not raised"),
        1
    );

    assert!(stored_project_id(&db, "task-fine").await.is_some());
    assert_eq!(stored_project_id(&db, "task-broken").await, None);
}

#[tokio::test]
async fn running_the_pass_twice_registers_one_project() {
    let (_dir, db) = connect().await;
    let mut item = item("task-repeat");
    item.execution_repository = Some("acme/widgets".into());
    db.create_task_board_item(item).await.expect("create item");
    strip_attribution(&db).await;

    db.reattribute_unattributed_task_board_items()
        .await
        .expect("first pass");
    let after_first = stored_project_id(&db, "task-repeat").await;
    assert_eq!(
        db.reattribute_unattributed_task_board_items()
            .await
            .expect("second pass"),
        0
    );

    assert_eq!(stored_project_id(&db, "task-repeat").await, after_first);
    assert_eq!(db.list_task_board_projects().await.expect("list").len(), 1);
}

async fn revision_and_updated_at(db: &AsyncDaemonDb, item_id: &str) -> (i64, String) {
    sqlx::query_as::<_, (i64, String)>(
        "SELECT revision, updated_at FROM task_board_items WHERE item_id = ?1",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("read the item's revision")
}

async fn connect() -> (TempDir, AsyncDaemonDb) {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    (dir, db)
}

fn item(id: &str) -> TaskBoardItem {
    TaskBoardItem::new(
        id.to_owned(),
        "Orphaned".to_owned(),
        "Body".to_owned(),
        "2026-07-26T10:00:00Z".to_owned(),
    )
}
