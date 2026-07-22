use sqlx::{query_as, query_scalar};

use super::*;

#[tokio::test]
async fn public_position_mutations_audit_once_with_authenticated_actor_and_sequence() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-22T10:00:00Z"))
        .await
        .expect("create a");
    let before = db.task_board_items_snapshot(None).await.expect("snapshot");
    let set = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "a".into(),
            status: Some(TaskBoardStatus::Todo),
            lane_position: 0,
            actor: "authenticated-control".into(),
            expected_item_revision: revision(&before, "a"),
            expected_items_change_seq: before.items_change_seq,
        })
        .await
        .expect("set position");
    assert_eq!(
        set.item.lane_set_at.as_deref(),
        Some(set.item.updated_at.as_str())
    );
    let audit: (String, String, i64, i64) = query_as(
        "SELECT kind, actor, json_extract(payload_json, '$.items_change_seq'),
         json_extract(payload_json, '$.to.index') FROM audit_events WHERE subject = ?1",
    )
    .bind("a")
    .fetch_one(db.pool())
    .await
    .expect("position audit");
    assert_eq!(
        audit,
        (
            "task_board.item.position_set".into(),
            "authenticated-control".into(),
            set.items_change_seq,
            0
        )
    );
    let reset = db
        .reset_task_board_lane_position(TaskBoardLaneResetInput {
            item_id: "a".into(),
            actor: "authenticated-control".into(),
            expected_item_revision: set.item_revision,
            expected_items_change_seq: set.items_change_seq,
        })
        .await
        .expect("reset position");
    let count: i64 = query_scalar("SELECT COUNT(*) FROM audit_events WHERE subject = ?1 AND kind LIKE 'task_board.item.position_%'")
        .bind("a").fetch_one(db.pool()).await.expect("count audits");
    assert_eq!(count, 2);
    assert_eq!(reset.item.lane_position, None);
}

#[tokio::test]
async fn reset_rejects_default_and_deleted_items_without_audit_or_sequence_change() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-22T10:00:00Z"))
        .await
        .expect("create a");
    let default_snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    let default_error = db
        .reset_task_board_lane_position(TaskBoardLaneResetInput {
            item_id: "a".into(),
            actor: "control".into(),
            expected_item_revision: revision(&default_snapshot, "a"),
            expected_items_change_seq: default_snapshot.items_change_seq,
        })
        .await
        .expect_err("default placement rejects reset");
    assert_eq!(default_error.code(), "KSRCLI084");
    assert!(default_error.to_string().contains("no explicit position"));
    assert_eq!(
        crate::daemon::http::error_status_and_body(&default_error).0,
        axum::http::StatusCode::BAD_REQUEST
    );
    assert_eq!(
        db.task_board_items_snapshot(None)
            .await
            .expect("snapshot")
            .items_change_seq,
        default_snapshot.items_change_seq
    );

    db.delete_task_board_item("a").await.expect("delete a");
    let deleted = db.task_board_item_snapshot("a").await.expect("tombstone");
    let deleted_sequence = query_scalar::<_, i64>(
        "SELECT COALESCE(change_seq, 0) FROM change_tracking WHERE scope = 'task_board:items'",
    )
    .fetch_one(db.pool())
    .await
    .expect("sequence");
    let deleted_error = db
        .reset_task_board_lane_position(TaskBoardLaneResetInput {
            item_id: "a".into(),
            actor: "control".into(),
            expected_item_revision: deleted.item_revision,
            expected_items_change_seq: deleted_sequence,
        })
        .await
        .expect_err("deleted placement rejects reset");
    assert_eq!(deleted_error.code(), "KSRCLI084");
    assert!(deleted_error.to_string().contains("deleted"));
    assert_eq!(
        crate::daemon::http::error_status_and_body(&deleted_error).0,
        axum::http::StatusCode::BAD_REQUEST
    );
    assert_eq!(
        query_scalar::<_, i64>(
            "SELECT COALESCE(change_seq, 0) FROM change_tracking WHERE scope = 'task_board:items'"
        )
        .fetch_one(db.pool())
        .await
        .expect("sequence"),
        deleted_sequence
    );
    let deleted_set_error = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "a".into(),
            status: Some(TaskBoardStatus::Todo),
            lane_position: 0,
            actor: "control".into(),
            expected_item_revision: deleted.item_revision,
            expected_items_change_seq: deleted_sequence,
        })
        .await
        .expect_err("deleted item rejects set position");
    assert_eq!(deleted_set_error.code(), "KSRCLI084");
    assert_eq!(
        crate::daemon::http::error_status_and_body(&deleted_set_error).0,
        axum::http::StatusCode::BAD_REQUEST
    );
    let position_audits: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events WHERE subject = ?1 AND kind LIKE 'task_board.item.position_%'",
    )
    .bind("a")
    .fetch_one(db.pool())
    .await
    .expect("count position audits");
    assert_eq!(position_audits, 0);
}
