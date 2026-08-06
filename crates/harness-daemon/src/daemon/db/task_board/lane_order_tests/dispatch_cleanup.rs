use super::*;

#[tokio::test]
async fn cross_lane_position_transition_runs_terminal_dispatch_cleanup() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("active", "2026-07-22T10:00:00Z"))
        .await
        .expect("create active item");
    let snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    let lifecycle = build_dispatch_plans_with_policy(
        &[item_from(&snapshot, "active").clone()],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &std::collections::HashMap::new(),
    )
    .remove(0)
    .applied_lifecycle();
    db.link_and_enqueue_task_board_dispatch("active", "session", "work", &lifecycle)
        .await
        .expect("activate item");
    let active = db
        .task_board_items_snapshot(None)
        .await
        .expect("active snapshot");
    let moved = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "active".into(),
            status: Some(TaskBoardStatus::Done),
            lane_position: 0,
            actor: "control-user".into(),
            expected_item_revision: revision(&active, "active"),
            expected_items_change_seq: active.items_change_seq,
        })
        .await
        .expect("terminal cross-lane placement");
    assert_eq!(moved.item.status, TaskBoardStatus::Done);
    let dispatch_status: String =
        query_scalar("SELECT status FROM task_board_dispatch_intents WHERE item_id = ?1")
            .bind("active")
            .fetch_one(db.pool())
            .await
            .expect("terminal dispatch state");
    assert_eq!(dispatch_status, "failed");
    let active_admissions: i64 = query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_admission_ledger
         WHERE intent_id IN (SELECT intent_id FROM task_board_dispatch_intents WHERE item_id = ?1)
           AND state IN ('reserved', 'committed')",
    )
    .bind("active")
    .fetch_one(db.pool())
    .await
    .expect("active admissions");
    assert_eq!(
        active_admissions, 0,
        "terminal move leaves no live admission"
    );
}
