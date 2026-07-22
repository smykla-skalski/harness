use super::*;

#[tokio::test]
async fn same_lane_default_anchor_compacts_before_inserting_the_requested_slot() {
    let (directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-22T10:00:00Z"))
        .await
        .expect("create default item");
    let mut automatic = item("b", "2026-07-22T10:01:00Z");
    automatic.priority = TaskBoardPriority::High;
    db.create_task_board_item(automatic)
        .await
        .expect("create automatic anchor");
    db.place_task_board_item_automatically("b", 1, "provider-sync".into())
        .await
        .expect("place automatic anchor")
        .expect("automatic anchor result");
    let before = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_positions(&before, &["a", "b"]);
    let b_revision = revision(&before, "b");
    let manual = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "a".into(),
            status: None,
            lane_position: 0,
            actor: "control-user".into(),
            expected_item_revision: revision(&before, "a"),
            expected_items_change_seq: before.items_change_seq,
        })
        .await
        .expect("anchor default at its derived slot");
    assert!(manual.shifted.is_empty(), "b returns to its original slot");
    let after = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(after.items_change_seq, before.items_change_seq + 1);
    assert_positions(&after, &["a", "b"]);
    assert_eq!(item_from(&after, "b").lane_position, Some(1));
    assert_eq!(revision(&after, "b"), b_revision);
    let shifted_count: i64 = query_scalar(
        "SELECT json_array_length(payload_json, '$.shifted') FROM audit_events
         WHERE subject = ?1 AND kind = 'task_board.item.lane_position_changed'",
    )
    .bind("a")
    .fetch_one(db.pool())
    .await
    .expect("anchor audit");
    assert_eq!(shifted_count, 0, "audit records no net shifted item");
    drop(db);
    let restarted = AsyncDaemonDb::connect(&directory.path().join("harness.db"))
        .await
        .expect("restart database");
    let restored = restarted.task_board_items_snapshot(None).await.expect("restored snapshot");
    assert_positions(&restored, &["a", "b"]);
}
