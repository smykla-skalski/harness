use sqlx::query_scalar;

use super::{clean_restore_patch, connect, exclusion_context, pre_dispatch_item};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::types::ExternalRefProvider;
use crate::task_board::{
    ExternalProvider, ProviderExclusionAuditContext, ProviderExclusionRestoreOutcome,
    TaskBoardConflictState, TaskBoardSyncConflict,
};

fn conflict(
    conflict_id: &str,
    field: &str,
    external_ref: &str,
    item_revision: i64,
) -> TaskBoardSyncConflict {
    TaskBoardSyncConflict {
        conflict_id: conflict_id.into(),
        item_id: "item-1".into(),
        provider: ExternalRefProvider::GitHub,
        external_ref: external_ref.into(),
        field: field.into(),
        base_value: serde_json::json!("base"),
        local_value: serde_json::json!("local"),
        remote_value: serde_json::json!("remote"),
        item_revision,
        provider_revision: Some("provider-revision".into()),
        state: TaskBoardConflictState::Open,
    }
}

#[tokio::test]
async fn restore_publishes_conflicts_and_leaves_the_tombstone_when_fields_disagree() {
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

    let conflicts = vec![conflict(
        "item-1:github:42:title",
        "title",
        "42",
        hidden.item_revision,
    )];
    let outcome = db
        .restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            TaskBoardItemPatch {
                title: Some("Would-be restored title".into()),
                ..TaskBoardItemPatch::default()
            },
            &exclusion_context("42"),
            Some(conflicts),
        )
        .await
        .expect("restore call succeeds");

    assert!(
        matches!(outcome, ProviderExclusionRestoreOutcome::ConflictPublished),
        "disagreeing fields must publish a conflict instead of restoring"
    );

    let current = db.task_board_item("item-1").await.expect("current item");
    assert!(
        current.is_deleted(),
        "a published conflict must leave the tombstone in place"
    );
    assert_eq!(
        current.title, "Title",
        "the conflicting patch must never apply"
    );

    let open = db
        .open_task_board_sync_conflicts()
        .await
        .expect("open conflicts");
    assert_eq!(open.len(), 1);
    assert_eq!(open[0].field, "title");

    let restored_count: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events
         WHERE kind = 'task_board.item.provider_exclusion_restored' AND subject = 'item-1'",
    )
    .fetch_one(db.pool())
    .await
    .expect("count restore audit events");
    assert_eq!(
        restored_count, 0,
        "a conflict-blocked restore must never also emit a restore audit event"
    );
}

#[tokio::test]
async fn restore_supersedes_stale_conflicts_and_proceeds_when_fields_converge() {
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

    // A prior round left an open conflict for this exact provider ref.
    db.replace_open_task_board_sync_conflicts(
        "item-1",
        ExternalProvider::GitHub,
        "42",
        hidden.item_revision,
        &[conflict(
            "item-1:github:42:title",
            "title",
            "42",
            hidden.item_revision,
        )],
    )
    .await
    .expect("seed a stale open conflict");

    let outcome = db
        .restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            clean_restore_patch(),
            &exclusion_context("42"),
            Some(Vec::new()),
        )
        .await
        .expect("restore call succeeds");

    assert!(
        matches!(outcome, ProviderExclusionRestoreOutcome::Restored(_)),
        "no remaining conflicting fields must let the restore proceed"
    );

    let open = db
        .open_task_board_sync_conflicts()
        .await
        .expect("open conflicts");
    assert!(
        open.is_empty(),
        "a round that stops conflicting must supersede the stale open row, not leave it behind"
    );
}

#[tokio::test]
async fn restore_conflict_scope_uses_the_incoming_ref_not_the_stored_one() {
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

    // The row's own stored ref is the legacy bare form ("42"), but the
    // provider now reports a qualified cross-repo form for the same task;
    // conflicts are stamped with that incoming ref, not the stored one.
    let context = ProviderExclusionAuditContext {
        provider: ExternalRefProvider::GitHub,
        incoming_external_ref: "owner/repo#42".into(),
        stored_external_ref: "42".into(),
        matched_label: "duplicate".into(),
    };
    let conflicts = vec![conflict(
        "item-1:github:owner/repo#42:title",
        "title",
        "owner/repo#42",
        hidden.item_revision,
    )];

    let outcome = db
        .restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            TaskBoardItemPatch::default(),
            &context,
            Some(conflicts),
        )
        .await
        .expect("a legacy stored ref must not block conflict persistence against a qualified incoming ref");

    assert!(matches!(
        outcome,
        ProviderExclusionRestoreOutcome::ConflictPublished
    ));
    let open = db
        .open_task_board_sync_conflicts()
        .await
        .expect("open conflicts");
    assert_eq!(open.len(), 1);
    assert_eq!(open[0].external_ref, "owner/repo#42");
}
