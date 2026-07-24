use super::super::TaskBoardTriageOverrideSetInput;
use super::*;
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, OVERRIDE_PLACEMENT_PRODUCER, TaskBoardLaneOrigin,
    TaskBoardPriority, TriageVerdict,
};

async fn seed_with_override(db: &AsyncDaemonDb, item_id: &str) {
    db.create_task_board_item(backlog_item(item_id))
        .await
        .expect("seed item");
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: item_id.into(),
        verdict: TriageVerdict::Todo,
        actor: "operator-1".into(),
        reason: None,
        expected_item_revision: revision(db, item_id).await,
        expected_items_change_seq: seq(db).await,
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

async fn clear_dispatch_reservation(db: &AsyncDaemonDb, item_id: &str) {
    sqlx::query("DELETE FROM task_board_dispatch_intents WHERE item_id = ?1")
        .bind(item_id)
        .execute(db.pool())
        .await
        .expect("clear dispatch reservation");
}

/// A dispatch reservation freezes an overridden Todo item's rank even when
/// its priority evidence changes underneath it -- rerank resumes as soon as
/// the reservation clears.
#[tokio::test]
async fn active_dispatch_reservation_suppresses_override_rerank_until_it_clears() {
    let (_directory, db) = connect().await;
    let mut sibling = backlog_item("sibling");
    sibling.status = TaskBoardStatus::Todo;
    sibling.priority = TaskBoardPriority::High;
    sibling.lane_position = Some(0);
    sibling.lane_origin = Some(TaskBoardLaneOrigin::Automatic {
        producer: BUILTIN_V1_EVALUATOR_IDENTITY.to_string(),
    });
    sibling.lane_set_at = Some("2026-07-23T00:00:00Z".into());
    db.create_task_board_item(sibling)
        .await
        .expect("seed higher-priority sibling");
    seed_with_override(&db, "item-1").await;
    let after_set = db
        .find_task_board_item("item-1")
        .await
        .expect("read item")
        .expect("exists");
    assert_eq!(
        after_set.lane_position,
        Some(1),
        "ranks below the higher-priority sibling"
    );

    seed_active_dispatch_reservation(&db, "item-1").await;
    let mutation = db
        .update_task_board_item_with_provider_triage("item-1", |item| {
            item.priority = TaskBoardPriority::Critical;
            Ok(true)
        })
        .await
        .expect("provider reconcile never rejects")
        .expect("mutation applied");
    assert_eq!(
        mutation.item.lane_position,
        Some(1),
        "rerank stays frozen while a dispatch reservation is active"
    );
    assert_eq!(
        mutation.item.lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: OVERRIDE_PLACEMENT_PRODUCER.to_string()
        }),
        "provenance is untouched, not silently rewritten"
    );

    clear_dispatch_reservation(&db, "item-1").await;
    let recomputed = db
        .update_task_board_item_with_provider_triage("item-1", |item| {
            item.tags = vec!["kind/bug".into()];
            Ok(true)
        })
        .await
        .expect("provider reconcile never rejects")
        .expect("mutation applied");
    assert_eq!(
        recomputed.item.lane_position,
        Some(0),
        "once the reservation clears, the next eligible write reranks above the now-lower-priority sibling"
    );
}
