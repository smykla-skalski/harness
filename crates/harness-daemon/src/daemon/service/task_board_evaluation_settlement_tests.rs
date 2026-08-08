use super::*;

#[tokio::test]
async fn legacy_translation_leaves_a_recoverable_worker_stop_debt() {
    let fixture = fixture().await;
    let item = create_item(&fixture, "board-1", Some("session-1")).await;
    seed_active_dispatch_reservation(&fixture.db, &item.id).await;
    sqlx::query(
        "UPDATE task_board_dispatch_intents
         SET status = 'completed', completed_at = ?2
         WHERE intent_id = 'intent-1' AND item_id = ?1",
    )
    .bind(&item.id)
    .bind(NOW)
    .execute(fixture.db.pool())
    .await
    .expect("finish dispatch intent");

    translate_session_task(&fixture.db, &item, &work_item(TaskStatus::Done), false)
        .await
        .expect("translate completed Session task");

    let pending = fixture
        .db
        .pending_task_board_work_item_worker_settlements(10)
        .await
        .expect("load worker settlement debt");
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].board_item_id, item.id);
    assert_eq!(pending[0].work_item_id, "work-board-1");
    assert_eq!(pending[0].worker_id, "codex-intent-1");

    fixture
        .db
        .settle_task_board_work_item_worker("board-1", "work-board-1")
        .await
        .expect("record recovered worker stop");
    assert!(
        fixture
            .db
            .pending_task_board_work_item_worker_settlements(10)
            .await
            .expect("reload worker settlement debt")
            .is_empty()
    );
}
