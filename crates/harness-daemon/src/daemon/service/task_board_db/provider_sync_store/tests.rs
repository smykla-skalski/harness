use tempfile::tempdir;

use super::*;
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db_open::AsyncDaemonDbConnect;
use crate::task_board::{
    ExternalCreateOutcome, ExternalRefProvider, ExternalRefSyncState, ExternalSyncField,
    ExternalTaskRef, TaskBoardConflictState, TaskBoardExternalCreateBegin,
    TaskBoardExternalCreateFinalizeDisposition, TaskBoardExternalCreateIntent,
};

#[tokio::test]
async fn external_sync_update_rejects_a_concurrent_local_edit() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
    let db = AsyncDaemonDbHandle(db);
    let created = db
        .create_task_board_item(TaskBoardItem::new(
            "task-concurrent-sync".into(),
            "Original title".into(),
            "Original body".into(),
            "2026-07-11T12:00:00Z".into(),
        ))
        .await
        .expect("create item")
        .item;
    db.update_task_board_item(&created.id, |item| {
        item.body = "Concurrent local edit".into();
        Ok(true)
    })
    .await
    .expect("local edit");
    let handle = db.clone();

    let error = <AsyncDaemonDbHandle as TaskBoardSyncStore>::update_item(
        &handle,
        &created,
        TaskBoardItemPatch {
            title: Some("Remote title".into()),
            ..TaskBoardItemPatch::default()
        },
    )
    .await
    .expect_err("stale sync snapshot must be rejected");
    let current = db.task_board_item(&created.id).await.expect("current item");

    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(current.title, "Original title");
    assert_eq!(current.body, "Concurrent local edit");
}

#[tokio::test]
async fn external_create_store_delegates_the_durable_intent_lifecycle() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
    let db = AsyncDaemonDbHandle(db);
    db.create_task_board_item(TaskBoardItem::new(
        "task-create-store".into(),
        "Create title".into(),
        "Create body".into(),
        "2026-07-16T15:00:00Z".into(),
    ))
    .await
    .expect("create item");
    let handle = db.clone();

    let started =
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::begin_external_create_intent(
            &handle,
            "task-create-store",
            ExternalProvider::GitHub,
            "acme/widgets",
            "acme/widgets",
        )
        .await
        .expect("begin create");
    let TaskBoardExternalCreateBegin::Started(intent) = started else {
        panic!("expected a newly started create intent");
    };
    assert_eq!(
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::list_in_flight_external_create_intents(
            &handle,
            ExternalProvider::GitHub
        )
        .await
        .expect("list in-flight"),
        vec![intent.clone()]
    );
    assert_eq!(
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::external_create_intent_by_create_key(
            &handle,
            ExternalProvider::GitHub,
            &intent.create_key,
        )
        .await
        .expect("lookup intent"),
        Some(intent.clone())
    );

    let (outcome, baseline) = create_evidence(&intent);
    let created =
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::record_external_create_outcome(
            &handle, &intent, &outcome, &baseline,
        )
        .await
        .expect("record create outcome");
    assert_eq!(
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::list_created_external_create_intents(
            &handle
        )
        .await
        .expect("list created"),
        vec![created.clone()]
    );
    let finalized =
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::finalize_external_create_intent(
            &handle, &created,
        )
        .await
        .expect("finalize create");

    assert_eq!(
        finalized.disposition,
        TaskBoardExternalCreateFinalizeDisposition::Attached
    );
    assert_eq!(
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::external_create_intent_by_create_key(
            &handle,
            ExternalProvider::GitHub,
            &intent.create_key,
        )
        .await
        .expect("lookup attached intent"),
        Some(finalized.intent.clone())
    );
    assert_eq!(
        <AsyncDaemonDbHandle as TaskBoardExternalCreateStore>::list_pending_external_create_follow_ups(
            &handle,
            Some(ExternalProvider::GitHub),
        )
        .await
        .expect("list pending attached receipts"),
        vec![finalized.intent]
    );
}

#[tokio::test]
async fn sync_store_delegates_field_scoped_conflict_supersession() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
    let db = AsyncDaemonDbHandle(db);
    db.create_task_board_item(TaskBoardItem::new(
        "task-conflict-store".into(),
        "Conflict title".into(),
        String::new(),
        "2026-07-16T15:00:00Z".into(),
    ))
    .await
    .expect("create item");
    db.replace_open_task_board_sync_conflicts(
        "task-conflict-store",
        ExternalProvider::GitHub,
        "acme/widgets#17",
        1,
        &[
            conflict("conflict-title", "title"),
            conflict("conflict-future", "future_field"),
        ],
    )
    .await
    .expect("record conflicts");
    let handle = db.clone();

    <AsyncDaemonDbHandle as TaskBoardSyncStore>::supersede_open_sync_conflicts(
        &handle,
        "task-conflict-store",
        ExternalProvider::GitHub,
        "acme/widgets#17",
        1,
        &[ExternalSyncField::Title],
    )
    .await
    .expect("supersede title conflict");

    let open = db
        .open_task_board_sync_conflicts()
        .await
        .expect("open conflicts");
    assert_eq!(open.len(), 1);
    assert_eq!(open[0].field, "future_field");
}

fn create_evidence(
    intent: &TaskBoardExternalCreateIntent,
) -> (ExternalCreateOutcome, crate::task_board::ExternalRef) {
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "acme/widgets#17")
        .with_url("https://example.invalid/acme/widgets/issues/17");
    let outcome = ExternalCreateOutcome {
        reference: reference.clone(),
        provider_revision: Some("provider-revision".into()),
        provider_project_id: Some("acme/widgets".into()),
    };
    let mut baseline = reference.into_core_ref();
    baseline.sync_state = Some(ExternalRefSyncState {
        title: Some(intent.snapshot.title.clone()),
        body: Some(intent.snapshot.body.clone()),
        status: Some(TaskBoardStatus::Inbox),
        project_id: Some("acme/widgets".into()),
        updated_at: Some("provider-revision".into()),
        synced_at: Some("2026-07-16T15:01:00Z".into()),
        labels: Vec::new(),
    });
    (outcome, baseline)
}

fn conflict(conflict_id: &str, field: &str) -> TaskBoardSyncConflict {
    TaskBoardSyncConflict {
        conflict_id: conflict_id.into(),
        item_id: "task-conflict-store".into(),
        provider: ExternalRefProvider::GitHub,
        external_ref: "acme/widgets#17".into(),
        field: field.into(),
        base_value: serde_json::json!("base"),
        local_value: serde_json::json!("local"),
        remote_value: serde_json::json!("remote"),
        item_revision: 1,
        provider_revision: Some("provider-revision".into()),
        state: TaskBoardConflictState::Open,
    }
}
