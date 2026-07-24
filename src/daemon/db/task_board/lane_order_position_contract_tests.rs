use sqlx::{query_as, query_scalar};

use super::super::TaskBoardTriageOverrideSetInput;
use super::*;
use crate::task_board::{OVERRIDE_PLACEMENT_PRODUCER, TriageVerdict};

async fn seed_todo_override(db: &AsyncDaemonDb, item_id: &str, verdict: TriageVerdict) {
    let snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: item_id.into(),
        verdict,
        actor: "operator-1".into(),
        reason: None,
        expected_item_revision: revision(&snapshot, item_id),
        expected_items_change_seq: snapshot.items_change_seq,
    })
    .await
    .expect("set override");
}

async fn seed_active_dispatch_reservation(db: &AsyncDaemonDb, item_id: &str) {
    sqlx::query(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, attempts, available_at, claim_token, claimed_at,
             created_at, updated_at
         ) VALUES ('intent-1', ?1, 'session-1', 'work-1', 'workflow-1', '{}',
                   'held', 0, '2026-07-23T00:00:00Z', NULL, NULL,
                   '2026-07-23T00:00:00Z', '2026-07-23T00:00:00Z')",
    )
    .bind(item_id)
    .execute(db.pool())
    .await
    .expect("seed dispatch reservation");
}

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

#[tokio::test]
async fn reset_reapplies_an_active_todo_override_instead_of_leaving_it_unranked() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-23T10:00:00Z"))
        .await
        .expect("create a");
    seed_todo_override(&db, "a", TriageVerdict::Todo).await;
    let placed = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(
        item_from(&placed, "a").lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: OVERRIDE_PLACEMENT_PRODUCER.to_string()
        })
    );

    let reset = db
        .reset_task_board_lane_position(TaskBoardLaneResetInput {
            item_id: "a".into(),
            actor: "control-user".into(),
            expected_item_revision: revision(&placed, "a"),
            expected_items_change_seq: placed.items_change_seq,
        })
        .await
        .expect("reset returns to override-derived ordering, not an error");
    assert_eq!(reset.item.status, TaskBoardStatus::Todo);
    assert_eq!(
        reset.item.lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: OVERRIDE_PLACEMENT_PRODUCER.to_string()
        }),
        "the override's own producer must be reasserted, not left unranked with no producer"
    );
    assert!(
        reset.item.lane_position.is_some(),
        "still ranked, not stranded unranked"
    );
    assert_eq!(reset.items_change_seq, placed.items_change_seq + 1);
}

#[tokio::test]
async fn reset_reapplies_an_active_undecided_override_by_demoting_to_backlog() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-23T10:00:00Z"))
        .await
        .expect("create a");
    let snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    let manual = db
        .set_task_board_lane_position(TaskBoardLanePositionInput {
            item_id: "a".into(),
            status: Some(TaskBoardStatus::Todo),
            lane_position: 0,
            actor: "control-user".into(),
            expected_item_revision: revision(&snapshot, "a"),
            expected_items_change_seq: snapshot.items_change_seq,
        })
        .await
        .expect("manual anchor");
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: "a".into(),
        verdict: TriageVerdict::Undecided,
        actor: "operator-1".into(),
        reason: None,
        expected_item_revision: manual.item_revision,
        expected_items_change_seq: manual.items_change_seq,
    })
    .await
    .expect("set undecided override");
    let overridden = db.task_board_items_snapshot(None).await.expect("snapshot");
    let overridden_a = item_from(&overridden, "a");
    assert_eq!(
        overridden_a.status,
        TaskBoardStatus::Backlog,
        "the override's status win applies even to a manual anchor"
    );
    assert_eq!(
        overridden_a.lane_position,
        Some(0),
        "the manual anchor's slot survives the override's status flip"
    );

    let reset = db
        .reset_task_board_lane_position(TaskBoardLaneResetInput {
            item_id: "a".into(),
            actor: "control-user".into(),
            expected_item_revision: revision(&overridden, "a"),
            expected_items_change_seq: overridden.items_change_seq,
        })
        .await
        .expect("reset converges the stray manual slot with the overridden Backlog status");
    assert_eq!(reset.item.status, TaskBoardStatus::Backlog);
    assert_eq!(reset.item.lane_position, None);
    assert_eq!(reset.item.lane_origin, None);
}

#[tokio::test]
async fn reset_rejects_atomically_when_override_and_dispatch_reservation_are_both_active() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-23T10:00:00Z"))
        .await
        .expect("create a");
    seed_todo_override(&db, "a", TriageVerdict::Todo).await;
    let placed = db.task_board_items_snapshot(None).await.expect("snapshot");
    seed_active_dispatch_reservation(&db, "a").await;
    let before_audits: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events WHERE subject = ?1 AND kind LIKE 'task_board.item.position_%'",
    )
    .bind("a")
    .fetch_one(db.pool())
    .await
    .expect("count position audits");

    let error = db
        .reset_task_board_lane_position(TaskBoardLaneResetInput {
            item_id: "a".into(),
            actor: "control-user".into(),
            expected_item_revision: revision(&placed, "a"),
            expected_items_change_seq: placed.items_change_seq,
        })
        .await
        .expect_err("an active dispatch reservation blocks resetting an overridden item");
    assert!(error.to_string().contains("dispatch reservation"));

    let after = db.task_board_items_snapshot(None).await.expect("snapshot");
    assert_eq!(
        after.items_change_seq, placed.items_change_seq,
        "the sequence must not move"
    );
    assert_eq!(
        revision(&after, "a"),
        revision(&placed, "a"),
        "the item must not move"
    );
    let after_audits: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events WHERE subject = ?1 AND kind LIKE 'task_board.item.position_%'",
    )
    .bind("a")
    .fetch_one(db.pool())
    .await
    .expect("count position audits");
    assert_eq!(after_audits, before_audits, "no audit for a rejected reset");
}

#[tokio::test]
async fn automatic_placement_never_overwrites_an_active_override_slot() {
    let (_directory, db) = connect().await;
    db.create_task_board_item(item("a", "2026-07-23T10:00:00Z"))
        .await
        .expect("create a");
    seed_todo_override(&db, "a", TriageVerdict::Todo).await;
    let placed = db.task_board_items_snapshot(None).await.expect("snapshot");
    let placed_a = item_from(&placed, "a").clone();

    let result = db
        .place_task_board_item_automatically("a", 5, "some-other-automation".into())
        .await
        .expect("automatic placement never errors for an eligible item");
    assert!(
        result.is_none(),
        "an active override's slot must never be overwritten by arbitrary automation"
    );

    let after = db.task_board_items_snapshot(None).await.expect("snapshot");
    let after_a = item_from(&after, "a");
    assert_eq!(after_a.lane_position, placed_a.lane_position);
    assert_eq!(after_a.lane_origin, placed_a.lane_origin);
    assert_eq!(
        after.items_change_seq, placed.items_change_seq,
        "a suppressed placement commits no change"
    );
}
