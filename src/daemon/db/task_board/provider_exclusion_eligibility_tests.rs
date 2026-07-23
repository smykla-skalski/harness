use super::{connect, exclusion_context, pre_dispatch_item};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::types::TaskBoardItemKind;

#[tokio::test]
async fn hides_a_pre_dispatch_umbrella_and_unparents_its_children() {
    let (_directory, db) = connect().await;
    let mut umbrella = pre_dispatch_item("umbrella");
    umbrella.kind = TaskBoardItemKind::Umbrella;
    let created_umbrella = db
        .create_task_board_item(umbrella)
        .await
        .expect("seed umbrella");
    let mut child = pre_dispatch_item("child");
    child.parent_item_id = Some("umbrella".into());
    db.create_task_board_item(child).await.expect("seed child");

    let hidden = db
        .hide_task_board_item_for_provider_exclusion(
            "umbrella",
            created_umbrella.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds")
        .expect("eligible umbrella is hidden");

    assert!(hidden.item.is_deleted());
    assert_eq!(
        db.task_board_item_snapshot("child")
            .await
            .expect("load child")
            .item
            .parent_item_id,
        None
    );
}
