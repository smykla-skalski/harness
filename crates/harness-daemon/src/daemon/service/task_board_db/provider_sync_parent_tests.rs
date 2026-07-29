use tempfile::tempdir;

use super::*;
use crate::task_board::store::OptionalFieldPatch;

#[tokio::test]
async fn provider_update_isolates_an_invalid_parent_and_applies_other_fields() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
    let created = db
        .create_task_board_item(TaskBoardItem::new(
            "provider-parent".into(),
            "Original title".into(),
            String::new(),
            "2026-07-23T12:00:00Z".into(),
        ))
        .await
        .expect("create item")
        .item;

    let updated = <AsyncDaemonDb as TaskBoardSyncStore>::update_item(
        &db,
        &created,
        TaskBoardItemPatch {
            title: Some("Remote title".into()),
            parent_item_id: OptionalFieldPatch::Set("missing-parent".into()),
            ..TaskBoardItemPatch::default()
        },
    )
    .await
    .expect("apply provider fields");

    assert_eq!(updated.title, "Remote title");
    assert_eq!(updated.parent_item_id, created.parent_item_id);
    assert_eq!(updated.child_order, created.child_order);
}

#[tokio::test]
async fn provider_update_with_only_an_invalid_parent_is_a_true_no_op() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
    let created = db
        .create_task_board_item(TaskBoardItem::new(
            "provider-parent-noop".into(),
            "Original title".into(),
            String::new(),
            "2026-07-23T12:00:00Z".into(),
        ))
        .await
        .expect("create item")
        .item;
    let before = db
        .task_board_items_snapshot(None)
        .await
        .expect("snapshot before");

    let updated = <AsyncDaemonDb as TaskBoardSyncStore>::update_item(
        &db,
        &created,
        TaskBoardItemPatch {
            parent_item_id: OptionalFieldPatch::Set("missing-parent".into()),
            ..TaskBoardItemPatch::default()
        },
    )
    .await
    .expect("isolate invalid parent");
    let after = db
        .task_board_items_snapshot(None)
        .await
        .expect("snapshot after");

    assert_eq!(updated, created);
    assert_eq!(after.items_change_seq, before.items_change_seq);
    assert_eq!(after.items[0].item_revision, before.items[0].item_revision);
}
