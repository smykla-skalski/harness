use sqlx::query_scalar;

use super::super::{
    clean_restore_patch, connect, exclusion_context, pre_dispatch_item, restored_item,
};
use crate::task_board::store::{OptionalFieldPatch, TaskBoardItemPatch};

#[tokio::test]
async fn restore_isolates_a_rejected_missing_parent_and_still_applies_the_rest() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");
    let hidden = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");

    let patch = TaskBoardItemPatch {
        title: Some("Un-excluded title".into()),
        tags: Some(vec!["kind/bug".into()]),
        parent_item_id: OptionalFieldPatch::Set("does-not-exist".into()),
        ..TaskBoardItemPatch::default()
    };
    let restored = restored_item(
        db.restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            patch,
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("restore call succeeds"),
    );

    assert!(!restored.is_deleted());
    assert_eq!(restored.tombstone_cause, None);
    assert_eq!(restored.title, "Un-excluded title");
    assert_eq!(restored.tags, vec!["kind/bug".to_string()]);
    assert_eq!(
        restored.parent_item_id, None,
        "the rejected parent link must leave parent_item_id untouched"
    );

    let restored_count: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events
         WHERE kind = 'task_board.item.provider_exclusion_restored' AND subject = 'item-1'",
    )
    .fetch_one(db.pool())
    .await
    .expect("count restore audit events");
    assert_eq!(
        restored_count, 1,
        "the isolated parent rejection must still commit as exactly one restore audit event"
    );
}

#[tokio::test]
async fn restore_isolates_a_rejected_self_parent_and_still_applies_the_rest() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");
    let hidden = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");

    let patch = TaskBoardItemPatch {
        title: Some("Un-excluded title".into()),
        tags: Some(Vec::new()),
        parent_item_id: OptionalFieldPatch::Set("item-1".into()),
        ..TaskBoardItemPatch::default()
    };
    let restored = restored_item(
        db.restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            patch,
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("restore call succeeds"),
    );

    assert!(!restored.is_deleted());
    assert_eq!(restored.title, "Un-excluded title");
    assert_eq!(
        restored.parent_item_id, None,
        "a rejected self-parent must never be persisted, isolated or not"
    );
}

#[tokio::test]
async fn restore_parent_patch_sets_a_new_parent() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(pre_dispatch_item("new-parent"))
        .await
        .expect("seed new parent");
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");
    let hidden = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");

    let patch = TaskBoardItemPatch {
        tags: Some(Vec::new()),
        parent_item_id: OptionalFieldPatch::Set("new-parent".into()),
        ..TaskBoardItemPatch::default()
    };
    let restored = restored_item(
        db.restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            patch,
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("restore call succeeds"),
    );

    assert_eq!(restored.parent_item_id, Some("new-parent".into()));
}

#[tokio::test]
async fn restore_parent_patch_clears_a_stale_parent() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(pre_dispatch_item("old-parent"))
        .await
        .expect("seed old parent");
    let mut item = pre_dispatch_item("item-1");
    item.parent_item_id = Some("old-parent".into());
    let created = db.create_task_board_item(item).await.expect("seed item");
    let hidden = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");
    assert_eq!(hidden.item.parent_item_id, Some("old-parent".into()));

    let patch = TaskBoardItemPatch {
        tags: Some(Vec::new()),
        parent_item_id: OptionalFieldPatch::Clear,
        ..TaskBoardItemPatch::default()
    };
    let restored = restored_item(
        db.restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            patch,
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("restore call succeeds"),
    );

    assert_eq!(restored.parent_item_id, None);
}

#[tokio::test]
async fn restore_parent_unchanged_patch_preserves_the_stored_parent() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(pre_dispatch_item("old-parent"))
        .await
        .expect("seed old parent");
    let mut item = pre_dispatch_item("item-1");
    item.parent_item_id = Some("old-parent".into());
    let created = db.create_task_board_item(item).await.expect("seed item");
    let hidden = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");

    let restored = restored_item(
        db.restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            clean_restore_patch(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("restore call succeeds"),
    );

    assert_eq!(
        restored.parent_item_id,
        Some("old-parent".into()),
        "an Unchanged parent patch must preserve whatever parent was stored, not clear it"
    );
}
