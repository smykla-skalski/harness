use super::*;

#[tokio::test]
async fn automatic_rerank_preserves_manual_anchor_and_updates_each_shift_once() {
    let (_directory, db) = connect().await;
    for (id, priority) in [
        ("manual", TaskBoardPriority::Medium),
        ("medium", TaskBoardPriority::Medium),
        ("low", TaskBoardPriority::Low),
        ("candidate", TaskBoardPriority::Low),
    ] {
        db.create_task_board_item(automatic_test_item(id, priority))
            .await
            .expect("create lane item");
    }
    anchor(&db, "manual", 0).await;
    for (item_id, position) in [("medium", 1), ("low", 2), ("candidate", 3)] {
        db.place_task_board_item_automatically(item_id, position, "test".into())
            .await
            .expect("place automatic item")
            .expect("automatic placement result");
    }
    db.update_task_board_item("candidate", |item| {
        item.priority = TaskBoardPriority::Critical;
        Ok(true)
    })
    .await
    .expect("raise candidate priority");
    let before = db.task_board_items_snapshot(None).await.expect("snapshot");

    let write = db
        .place_task_board_item_automatically("candidate", 1, "test".into())
        .await
        .expect("rerank candidate")
        .expect("automatic placement result");
    let after = db.task_board_items_snapshot(None).await.expect("snapshot");

    assert_positions(&after, &["manual", "candidate", "medium", "low"]);
    assert_eq!(after.items_change_seq, before.items_change_seq + 1);
    assert_eq!(
        revision(&after, "manual"),
        revision(&before, "manual"),
        "manual anchor revision stays unchanged"
    );
    for item_id in ["candidate", "medium", "low"] {
        assert_eq!(
            revision(&after, item_id),
            revision(&before, item_id) + 1,
            "{item_id} revision advances exactly once"
        );
    }
    let mut shifted = write
        .shifted
        .iter()
        .map(|shift| shift.item_id.as_str())
        .collect::<Vec<_>>();
    shifted.sort_unstable();
    assert_eq!(shifted, ["low", "medium"]);

    let payload: String = query_scalar(
        "SELECT payload_json FROM audit_events
         WHERE subject = 'candidate'
           AND kind = 'task_board.item.lane_position_changed'
           AND json_extract(payload_json, '$.items_change_seq') = ?1",
    )
    .bind(after.items_change_seq)
    .fetch_one(db.pool())
    .await
    .expect("automatic rerank audit");
    let payload: serde_json::Value = serde_json::from_str(&payload).expect("parse audit payload");
    let mut audited_shifted = payload["shifted"]
        .as_array()
        .expect("shifted audit array")
        .iter()
        .filter_map(|shift| shift["item_id"].as_str())
        .collect::<Vec<_>>();
    audited_shifted.sort_unstable();
    assert_eq!(audited_shifted, ["low", "medium"]);
}

#[tokio::test]
async fn triage_priority_change_reranks_automatic_cards_around_manual_anchor() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(automatic_test_item("manual", TaskBoardPriority::Medium))
        .await
        .expect("create manual item");
    anchor(&db, "manual", 0).await;
    for (id, priority, created_at) in [
        ("medium", TaskBoardPriority::Medium, "2026-07-23T10:00:00Z"),
        ("low", TaskBoardPriority::Low, "2026-07-23T10:01:00Z"),
        ("candidate", TaskBoardPriority::Low, "2026-07-23T10:02:00Z"),
    ] {
        db.create_task_board_item_with_triage(triage_test_item(id, priority, created_at))
            .await
            .expect("create triaged item");
    }
    let before = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_positions(&before, &["manual", "medium", "low", "candidate"]);

    db.update_task_board_item_with_triage("candidate", |item| {
        item.priority = TaskBoardPriority::Critical;
        Ok(true)
    })
    .await
    .expect("raise candidate priority")
    .expect("priority update");
    let after = db.task_board_items_snapshot(None).await.expect("snapshot");

    assert_positions(&after, &["manual", "candidate", "medium", "low"]);
    assert_eq!(after.items_change_seq, before.items_change_seq + 1);
    assert_eq!(
        revision(&after, "manual"),
        revision(&before, "manual"),
        "manual anchor revision stays unchanged"
    );
    for item_id in ["candidate", "medium", "low"] {
        assert_eq!(
            revision(&after, item_id),
            revision(&before, item_id) + 1,
            "{item_id} revision advances exactly once"
        );
    }
    let audit_payloads: Vec<String> = sqlx::query_scalar(
        "SELECT payload_json FROM audit_events
         WHERE subject = 'candidate'
           AND json_extract(payload_json, '$.items_change_seq') = ?1",
    )
    .bind(after.items_change_seq)
    .fetch_all(db.pool())
    .await
    .expect("triage rerank audits");
    assert_eq!(
        audit_payloads.len(),
        1,
        "triage rerank emits one semantic audit"
    );
    let audit: serde_json::Value =
        serde_json::from_str(&audit_payloads[0]).expect("parse triage audit");
    let mut shifted = audit["shifted"]
        .as_array()
        .expect("shifted audit array")
        .iter()
        .filter_map(|shift| shift["item_id"].as_str())
        .collect::<Vec<_>>();
    shifted.sort_unstable();
    assert_eq!(shifted, ["low", "medium"]);
}

fn automatic_test_item(id: &str, priority: TaskBoardPriority) -> TaskBoardItem {
    let mut item = item(id, "2026-07-23T10:00:00Z");
    item.priority = priority;
    item.work_item_id = Some(format!("seed-{id}"));
    item
}

fn triage_test_item(id: &str, priority: TaskBoardPriority, created_at: &str) -> TaskBoardItem {
    let mut item = item(id, created_at);
    item.status = TaskBoardStatus::Backlog;
    item.priority = priority;
    item.tags = vec!["kind/bug".into()];
    item
}
