use tempfile::tempdir;

use super::provider_external_creates_tests::{begin, connect, create_item, item, record};
use crate::task_board::{
    ExternalProvider, ExternalRefProvider, ExternalSyncField, TaskBoardConflictState,
    TaskBoardExternalCreateIntent, TaskBoardExternalCreateIntentState, TaskBoardSyncConflict,
};

#[tokio::test]
async fn pending_follow_up_query_is_provider_filtered_and_deterministic() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-follow-up-github")).await;
    create_item(&db, item("task-follow-up-todoist")).await;
    let github = attach(
        &db,
        "task-follow-up-github",
        ExternalProvider::GitHub,
        "example/repository#81",
    )
    .await;
    let todoist = attach(
        &db,
        "task-follow-up-todoist",
        ExternalProvider::Todoist,
        "todoist-task-81",
    )
    .await;

    assert_eq!(
        db.list_pending_task_board_external_create_follow_ups(None)
            .await
            .expect("list all pending follow-ups"),
        vec![github.clone(), todoist.clone()]
    );
    assert_eq!(
        db.list_pending_task_board_external_create_follow_ups(Some(ExternalProvider::Todoist))
            .await
            .expect("list Todoist follow-ups"),
        vec![todoist]
    );
    assert_eq!(
        db.list_pending_task_board_external_create_follow_ups(Some(ExternalProvider::GitHub))
            .await
            .expect("list GitHub follow-ups"),
        vec![github]
    );
}

#[tokio::test]
async fn audit_and_follow_up_ack_are_atomic_and_idempotent() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-follow-up-atomic")).await;
    let attached = attach(
        &db,
        "task-follow-up-atomic",
        ExternalProvider::GitHub,
        "example/repository#82",
    )
    .await;
    let incomplete = sqlx::query(
        "UPDATE task_board_external_create_intents
         SET follow_up_completed_at = '2026-07-16T18:00:00Z'
         WHERE intent_id = ?1",
    )
    .bind(&attached.intent_id)
    .execute(db.pool())
    .await
    .expect_err("follow-up timestamp without audit identity must fail");
    assert!(incomplete.to_string().contains("CHECK constraint failed"));
    sqlx::query(
        "CREATE TRIGGER fail_create_follow_up_audit
         BEFORE INSERT ON audit_events
         BEGIN SELECT RAISE(FAIL, 'simulated follow-up audit failure'); END",
    )
    .execute(db.pool())
    .await
    .expect("install audit failure");

    db.complete_task_board_external_create_follow_ups(std::slice::from_ref(&attached))
        .await
        .expect_err("audit failure must keep the receipt pending");
    assert_eq!(
        db.list_pending_task_board_external_create_follow_ups(None)
            .await
            .expect("pending after failed audit"),
        vec![attached.clone()]
    );
    sqlx::query("DROP TRIGGER fail_create_follow_up_audit")
        .execute(db.pool())
        .await
        .expect("remove audit failure");

    let events = db
        .complete_task_board_external_create_follow_ups(std::slice::from_ref(&attached))
        .await
        .expect("complete follow-up");
    assert_eq!(events.len(), 1);
    let event = &events[0];
    assert!(
        db.list_pending_task_board_external_create_follow_ups(None)
            .await
            .expect("pending after completion")
            .is_empty()
    );
    assert!(
        db.complete_task_board_external_create_follow_ups(std::slice::from_ref(&attached))
            .await
            .expect("repeat exact completion")
            .is_empty()
    );
    let stored = sqlx::query_as::<_, (Option<String>, Option<String>, i64)>(
        "SELECT follow_up_completed_at, follow_up_audit_event_id,
                (SELECT COUNT(*) FROM audit_events WHERE id = ?2)
         FROM task_board_external_create_intents WHERE intent_id = ?1",
    )
    .bind(&attached.intent_id)
    .bind(&event.id)
    .fetch_one(db.pool())
    .await
    .expect("read completion");
    assert!(stored.0.is_some());
    assert_eq!(stored.1.as_deref(), Some(event.id.as_str()));
    assert_eq!(stored.2, 1);
    assert_eq!(event.recorded_at, stored.0.expect("completion timestamp"));
    assert_eq!(
        event.payload_json.as_ref().expect("payload")["create_applied"].as_bool(),
        Some(true)
    );
}

#[tokio::test]
async fn follow_up_batch_failure_rolls_back_earlier_audit_and_ack_writes() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-follow-up-batch-first")).await;
    create_item(&db, item("task-follow-up-batch-second")).await;
    let first = attach(
        &db,
        "task-follow-up-batch-first",
        ExternalProvider::GitHub,
        "example/repository#85",
    )
    .await;
    let second = attach(
        &db,
        "task-follow-up-batch-second",
        ExternalProvider::GitHub,
        "example/repository#86",
    )
    .await;
    sqlx::query(
        "CREATE TRIGGER fail_second_create_follow_up_audit
         BEFORE INSERT ON audit_events
         WHEN NEW.subject = 'task-follow-up-batch-second'
         BEGIN SELECT RAISE(FAIL, 'simulated second follow-up failure'); END",
    )
    .execute(db.pool())
    .await
    .expect("install second audit failure");

    db.complete_task_board_external_create_follow_ups(&[first, second])
        .await
        .expect_err("batch failure must roll back every follow-up");

    assert_eq!(
        db.list_pending_task_board_external_create_follow_ups(None)
            .await
            .expect("pending follow-ups")
            .len(),
        2
    );
    let event_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM audit_events
         WHERE action_key = 'task_board.external_create_follow_up'",
    )
    .fetch_one(db.pool())
    .await
    .expect("follow-up event count");
    assert_eq!(event_count, 0);
}

#[tokio::test]
async fn pending_follow_up_query_uses_the_partial_index() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;

    let plan = sqlx::query_as::<_, (i64, i64, i64, String)>(
        "EXPLAIN QUERY PLAN
         SELECT intent_id FROM task_board_external_create_intents
         WHERE provider = 'github' AND state = 'attached'
           AND follow_up_completed_at IS NULL
           AND follow_up_audit_event_id IS NULL
         ORDER BY scope_id, attached_at, intent_id",
    )
    .fetch_all(db.pool())
    .await
    .expect("query plan");

    assert!(plan.iter().any(|row| {
        row.3
            .contains("idx_task_board_external_create_intents_pending_follow_up")
    }));
}

#[tokio::test]
async fn finalization_supersedes_only_fields_matching_the_final_item() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-follow-up-conflicts")).await;
    let intent = begin(&db, "task-follow-up-conflicts", ExternalProvider::GitHub).await;
    let created = record(&db, &intent, "example/repository#83").await;
    db.replace_open_task_board_sync_conflicts(
        "task-follow-up-conflicts",
        ExternalProvider::GitHub,
        "example/repository#83",
        1,
        &[
            conflict(
                "conflict-title",
                "task-follow-up-conflicts",
                "example/repository#83",
                ExternalSyncField::Title,
            ),
            conflict(
                "conflict-body",
                "task-follow-up-conflicts",
                "example/repository#83",
                ExternalSyncField::Body,
            ),
        ],
    )
    .await
    .expect("record create conflicts");
    db.update_task_board_item("task-follow-up-conflicts", |item| {
        item.title = "Concurrent local title".into();
        Ok(true)
    })
    .await
    .expect("edit title before finalization");

    db.finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize with conflict cleanup");

    let open = db
        .open_task_board_sync_conflicts()
        .await
        .expect("open conflicts");
    assert_eq!(open.len(), 1);
    assert_eq!(open[0].field, "title");
    assert_eq!(open[0].item_revision, 1);
}

#[tokio::test]
async fn conflict_cleanup_failure_rolls_back_attachment_and_receipt() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-follow-up-conflict-failure")).await;
    let intent = begin(
        &db,
        "task-follow-up-conflict-failure",
        ExternalProvider::GitHub,
    )
    .await;
    let created = record(&db, &intent, "example/repository#84").await;
    db.replace_open_task_board_sync_conflicts(
        "task-follow-up-conflict-failure",
        ExternalProvider::GitHub,
        "example/repository#84",
        1,
        &[conflict(
            "conflict-failure",
            "task-follow-up-conflict-failure",
            "example/repository#84",
            ExternalSyncField::Title,
        )],
    )
    .await
    .expect("record create conflict");
    sqlx::query(
        "CREATE TRIGGER fail_create_conflict_cleanup
         BEFORE UPDATE ON task_board_sync_conflicts
         BEGIN SELECT RAISE(FAIL, 'simulated conflict cleanup failure'); END",
    )
    .execute(db.pool())
    .await
    .expect("install conflict failure");

    db.finalize_task_board_external_create_intent(&created)
        .await
        .expect_err("conflict cleanup must roll back finalization");

    let item = db
        .task_board_item("task-follow-up-conflict-failure")
        .await
        .expect("reload item");
    assert!(item.external_refs.is_empty());
    let stored = db
        .task_board_external_create_intent(
            "task-follow-up-conflict-failure",
            ExternalProvider::GitHub,
        )
        .await
        .expect("reload intent")
        .expect("created intent");
    assert!(matches!(
        stored.state,
        TaskBoardExternalCreateIntentState::Created(_)
    ));
    assert_eq!(
        db.list_pending_task_board_external_create_follow_ups(None)
            .await
            .expect("pending follow-ups"),
        Vec::new()
    );
}

async fn attach(
    db: &crate::daemon::db::AsyncDaemonDb,
    item_id: &str,
    provider: ExternalProvider,
    external_id: &str,
) -> TaskBoardExternalCreateIntent {
    let intent = begin(db, item_id, provider).await;
    let created = record(db, &intent, external_id).await;
    db.finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize create")
        .intent
}

fn conflict(
    conflict_id: &str,
    item_id: &str,
    external_ref: &str,
    field: ExternalSyncField,
) -> TaskBoardSyncConflict {
    TaskBoardSyncConflict {
        conflict_id: conflict_id.into(),
        item_id: item_id.into(),
        provider: ExternalRefProvider::GitHub,
        external_ref: external_ref.into(),
        field: match field {
            ExternalSyncField::Title => "title",
            ExternalSyncField::Body => "body",
            _ => unreachable!("test only covers title and body"),
        }
        .into(),
        base_value: serde_json::json!("base"),
        local_value: serde_json::json!("local"),
        remote_value: serde_json::json!("remote"),
        item_revision: 1,
        provider_revision: Some("revision-0".into()),
        state: TaskBoardConflictState::Open,
    }
}
