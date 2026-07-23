use sqlx::query_scalar;

use super::{clean_restore_patch, connect, exclusion_context, pre_dispatch_item, restored_item};
use crate::daemon::db::TaskBoardTriageOverrideSetInput;
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{TaskBoardStatus, TriageVerdict};

/// A live, triage-eligible item under an active override that later gets
/// hidden for a provider exclusion must come back out of restore still in
/// the override's lane -- not wherever the refreshed machine decision alone
/// would place it (here, an empty-tags restore patch means the automatic
/// verdict is genuinely Undecided/Backlog). Restoring must never recreate
/// the effective-vs-item contradiction the override exists to prevent.
#[tokio::test]
async fn restore_reasserts_an_active_override_over_the_refreshed_automatic_decision() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");
    let expected_items_change_seq = db
        .task_board_items_snapshot(None)
        .await
        .expect("snapshot")
        .items_change_seq;
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: "item-1".into(),
        verdict: TriageVerdict::Todo,
        actor: "operator-1".into(),
        reason: None,
        expected_item_revision: created.item_revision,
        expected_items_change_seq,
    })
    .await
    .expect("set override");
    let overridden_revision: i64 =
        query_scalar("SELECT revision FROM task_board_items WHERE item_id = 'item-1'")
            .fetch_one(db.pool())
            .await
            .expect("read overridden revision");

    let hidden = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            overridden_revision,
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
        restored.status,
        TaskBoardStatus::Todo,
        "the active override must survive the restore, overriding the refreshed automatic Undecided verdict"
    );

    let current = db
        .task_board_triage_current("item-1")
        .await
        .expect("read triage current");
    assert!(
        current.triage_override.is_some(),
        "restoring must not itself clear the override"
    );
}
