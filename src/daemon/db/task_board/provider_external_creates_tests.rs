use tempfile::tempdir;

use super::ORCHESTRATOR_CHANGE_SCOPE;
use super::provider_external_create_rows::next_timestamp;
use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::{
    ExternalCreateOutcome, ExternalProvider, ExternalRefSyncState, ExternalSyncField,
    ExternalTaskRef, TaskBoardExternalCreateBegin, TaskBoardExternalCreateExisting,
    TaskBoardExternalCreateIntent, TaskBoardExternalCreateIntentState, TaskBoardItem,
    TaskBoardStatus,
};

#[tokio::test]
async fn concurrent_begin_admits_one_create_and_reuses_immutable_cross_scope_snapshot() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-create-reuse")).await;
    let before = sequence(&db).await;
    let first_db = db.clone();
    let second_db = db.clone();

    let (first, second) = tokio::join!(
        first_db.begin_task_board_external_create_intent(
            "task-create-reuse",
            ExternalProvider::GitHub,
            "scope-a",
            "Example/Repository",
        ),
        second_db.begin_task_board_external_create_intent(
            "task-create-reuse",
            ExternalProvider::GitHub,
            "scope-b",
            "example/repository",
        ),
    );
    let (first_started, first) = begin_intent(first.expect("first begin"));
    let (second_started, second) = begin_intent(second.expect("second begin"));

    assert_ne!(first_started, second_started);
    assert_eq!(first, second);
    assert_eq!(first.snapshot.title, "Original title");
    assert_eq!(first.snapshot.body, "Original body");
    assert_eq!(first.snapshot.status, TaskBoardStatus::Todo);
    assert_eq!(first.snapshot.provider_target, "example/repository");
    assert_eq!(
        first.changed_fields,
        vec![
            ExternalSyncField::Title,
            ExternalSyncField::Body,
            ExternalSyncField::Status,
        ]
    );
    uuid::Uuid::parse_str(&first.intent_id).expect("intent UUID");
    uuid::Uuid::parse_str(&first.create_key).expect("provider create UUID");
    assert_published(&db, before, ORCHESTRATOR_CHANGE_SCOPE).await;

    db.update_task_board_item("task-create-reuse", |current| {
        current.title = "Concurrent title".into();
        current.body = "Concurrent body".into();
        current.execution_repository = Some("other/repository".into());
        Ok(true)
    })
    .await
    .expect("concurrent item edit");
    let before_reuse = sequence(&db).await;
    let reused = db
        .begin_task_board_external_create_intent(
            "task-create-reuse",
            ExternalProvider::GitHub,
            "scope-c",
            "other/repository",
        )
        .await
        .expect("cross-scope reuse");
    let (started, reused) = begin_intent(reused);

    assert!(!started);
    assert_eq!(reused, first);
    assert_eq!(sequence(&db).await, before_reuse);
    assert_eq!(
        db.list_pending_task_board_external_create_intents(
            ExternalProvider::GitHub,
            &first.scope_id,
        )
        .await
        .expect("list original scope"),
        vec![first.clone()]
    );
    assert_eq!(
        db.task_board_external_create_intent("task-create-reuse", ExternalProvider::GitHub)
            .await
            .expect("active intent"),
        Some(first)
    );
}

#[tokio::test]
async fn begin_rejects_linked_or_tombstoned_items_without_churn() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    let mut linked = item("task-create-linked");
    linked.external_refs.push(
        ExternalTaskRef::new(ExternalProvider::GitHub, "example/repository#9").into_core_ref(),
    );
    create_item(&db, linked).await;
    let before_linked = sequence(&db).await;

    let linked_error = db
        .begin_task_board_external_create_intent(
            "task-create-linked",
            ExternalProvider::GitHub,
            "scope",
            "example/repository",
        )
        .await
        .expect_err("linked item must fail");
    assert_eq!(linked_error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(sequence(&db).await, before_linked);

    create_item(&db, item("task-create-tombstone")).await;
    db.delete_task_board_item("task-create-tombstone")
        .await
        .expect("tombstone item");
    let before_tombstone = sequence(&db).await;
    let tombstone_error = db
        .begin_task_board_external_create_intent(
            "task-create-tombstone",
            ExternalProvider::GitHub,
            "scope",
            "example/repository",
        )
        .await
        .expect_err("tombstoned item must fail");
    assert_eq!(tombstone_error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(sequence(&db).await, before_tombstone);
}

#[tokio::test]
async fn record_persists_exact_evidence_and_rejects_valid_drift_without_churn() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-create-record")).await;
    let intent = begin(&db, "task-create-record", ExternalProvider::GitHub).await;
    let (outcome, baseline) = create_evidence(&intent, "example/repository#41", "revision-1");
    let before = sequence(&db).await;

    let created = db
        .record_task_board_external_create_outcome(&intent, &outcome, &baseline)
        .await
        .expect("record outcome");
    assert_published(&db, before, ORCHESTRATOR_CHANGE_SCOPE).await;
    let evidence = created.created_evidence().expect("created evidence");
    assert_eq!(evidence.outcome, outcome);
    assert_eq!(evidence.provider_baseline, baseline);
    assert!(evidence.recorded_at > created.created_at);
    assert_exact_json(&db, &created, &outcome, &baseline).await;

    let before_retry = sequence(&db).await;
    let repeated = db
        .record_task_board_external_create_outcome(&intent, &outcome, &baseline)
        .await
        .expect("repeat exact outcome");
    assert_eq!(repeated, created);
    assert_eq!(sequence(&db).await, before_retry);

    let (drifted_outcome, drifted_baseline) =
        create_evidence(&intent, "example/repository#41", "revision-2");
    let error = db
        .record_task_board_external_create_outcome(&intent, &drifted_outcome, &drifted_baseline)
        .await
        .expect_err("different valid evidence must fail");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(sequence(&db).await, before_retry);
    assert_eq!(
        db.task_board_external_create_intent("task-create-record", ExternalProvider::GitHub)
            .await
            .expect("reload created intent"),
        Some(created)
    );
}

#[tokio::test]
async fn record_rejects_provider_revision_project_and_identity_mismatch() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-create-mismatch")).await;
    let intent = begin(&db, "task-create-mismatch", ExternalProvider::GitHub).await;
    let (outcome, baseline) = create_evidence(&intent, "example/repository#42", "revision-1");
    let before = sequence(&db).await;

    let mut revision_mismatch = outcome.clone();
    revision_mismatch.provider_revision = Some("revision-2".into());
    assert_record_conflict(&db, &intent, &revision_mismatch, &baseline).await;

    let mut project_mismatch = outcome.clone();
    project_mismatch.provider_project_id = Some("other/repository".into());
    assert_record_conflict(&db, &intent, &project_mismatch, &baseline).await;

    let mut provider_mismatch = outcome;
    provider_mismatch.reference.provider = ExternalProvider::Todoist;
    assert_record_conflict(&db, &intent, &provider_mismatch, &baseline).await;

    let (identity_mismatch, identity_baseline) =
        create_evidence(&intent, "other/repository#42", "revision-1");
    assert_record_conflict(&db, &intent, &identity_mismatch, &identity_baseline).await;
    assert_eq!(sequence(&db).await, before);
}

#[tokio::test]
async fn created_recovery_is_global_and_hard_delete_retains_active_evidence() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-create-github")).await;
    let mut todoist = item("task-create-todoist");
    todoist.project_id = Some("todoist-project".into());
    create_item(&db, todoist).await;
    let github = begin(&db, "task-create-github", ExternalProvider::GitHub).await;
    let todoist = begin(&db, "task-create-todoist", ExternalProvider::Todoist).await;
    let github = record(&db, &github, "example/repository#43").await;
    let todoist = record(&db, &todoist, "todoist-task-43").await;
    db.delete_task_board_item("task-create-github")
        .await
        .expect("tombstone created GitHub item");
    db.update_task_board_item("task-create-todoist", |current| {
        current.title = "Concurrent Todoist title".into();
        current.project_id = Some("todoist-project-concurrent".into());
        Ok(true)
    })
    .await
    .expect("edit Todoist item after create");
    let todoist_recovery = db
        .begin_task_board_external_create_intent(
            "task-create-todoist",
            ExternalProvider::Todoist,
            "replacement-scope",
            "todoist-project-concurrent",
        )
        .await
        .expect("recover Todoist create");
    assert!(matches!(
        todoist_recovery,
        TaskBoardExternalCreateBegin::Existing(TaskBoardExternalCreateExisting::Finalize(
            ref recovered
        )) if recovered == &todoist
    ));

    let mut recovered = db
        .list_created_task_board_external_create_intents()
        .await
        .expect("global created recovery");
    recovered.sort_by(|left, right| left.item_id.cmp(&right.item_id));
    let mut expected = vec![github.clone(), todoist];
    expected.sort_by(|left, right| left.item_id.cmp(&right.item_id));
    assert_eq!(recovered, expected);
    let delete_error =
        sqlx::query("DELETE FROM task_board_items WHERE item_id = 'task-create-github'")
            .execute(db.pool())
            .await
            .expect_err("active evidence must restrict hard delete");
    assert!(delete_error.to_string().contains("FOREIGN KEY"));
    assert_eq!(
        db.task_board_external_create_intent("task-create-github", ExternalProvider::GitHub)
            .await
            .expect("retained active intent"),
        Some(github)
    );
}

#[tokio::test]
async fn inconsistent_persisted_create_evidence_fails_closed_on_read() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-create-corrupt")).await;
    let intent = begin(&db, "task-create-corrupt", ExternalProvider::GitHub).await;
    let created = record(&db, &intent, "example/repository#44").await;
    sqlx::query(
        "UPDATE task_board_external_create_intents
         SET outcome_json = json_set(outcome_json, '$.provider_revision', 'corrupt')
         WHERE intent_id = ?1",
    )
    .bind(&created.intent_id)
    .execute(db.pool())
    .await
    .expect("corrupt outcome");

    let error = db
        .task_board_external_create_intent("task-create-corrupt", ExternalProvider::GitHub)
        .await
        .expect_err("inconsistent evidence must fail closed");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
}

#[test]
fn transition_timestamp_advances_when_wall_clock_has_not() {
    assert_eq!(
        next_timestamp("2999-12-31T23:59:58Z").expect("next timestamp"),
        "2999-12-31T23:59:59Z"
    );
}

#[tokio::test]
async fn record_and_finalize_advance_persisted_clock_without_wall_clock_rollover() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-create-monotonic")).await;
    let intent = begin(&db, "task-create-monotonic", ExternalProvider::GitHub).await;
    sqlx::query(
        "UPDATE task_board_external_create_intents
         SET created_at = '2999-12-31T23:59:58Z',
             updated_at = '2999-12-31T23:59:58Z'
         WHERE intent_id = ?1",
    )
    .bind(&intent.intent_id)
    .execute(db.pool())
    .await
    .expect("seed future create clock");
    let intent = db
        .task_board_external_create_intent("task-create-monotonic", ExternalProvider::GitHub)
        .await
        .expect("reload intent")
        .expect("active intent");

    let created = record(&db, &intent, "example/repository#60").await;
    let recorded_at = created
        .created_evidence()
        .expect("created evidence")
        .recorded_at
        .clone();
    let finalized = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize create");
    let TaskBoardExternalCreateIntentState::Attached(receipt) = finalized.intent.state else {
        panic!("expected attached receipt");
    };

    assert_eq!(recorded_at, "2999-12-31T23:59:59Z");
    assert_eq!(receipt.attached_at, "3000-01-01T00:00:00Z");
}

pub(super) async fn connect(dir: &tempfile::TempDir) -> AsyncDaemonDb {
    AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database")
}

pub(super) fn item(item_id: &str) -> TaskBoardItem {
    TaskBoardItem::new(
        item_id.into(),
        "Original title".into(),
        "Original body".into(),
        "2026-07-16T10:00:00Z".into(),
    )
}

pub(super) async fn create_item(db: &AsyncDaemonDb, item: TaskBoardItem) {
    db.create_task_board_item(item).await.expect("create item");
}

pub(super) async fn begin(
    db: &AsyncDaemonDb,
    item_id: &str,
    provider: ExternalProvider,
) -> TaskBoardExternalCreateIntent {
    let (target, scope) = match provider {
        ExternalProvider::GitHub => ("example/repository", "github-scope"),
        ExternalProvider::Todoist => ("todoist-project", "todoist-scope"),
    };
    match db
        .begin_task_board_external_create_intent(item_id, provider, scope, target)
        .await
        .expect("begin intent")
    {
        TaskBoardExternalCreateBegin::Started(intent) => intent,
        other => panic!("expected started intent, got {other:?}"),
    }
}

pub(super) async fn record(
    db: &AsyncDaemonDb,
    intent: &TaskBoardExternalCreateIntent,
    external_id: &str,
) -> TaskBoardExternalCreateIntent {
    let (outcome, baseline) = create_evidence(intent, external_id, "revision-1");
    db.record_task_board_external_create_outcome(intent, &outcome, &baseline)
        .await
        .expect("record intent")
}

fn begin_intent(decision: TaskBoardExternalCreateBegin) -> (bool, TaskBoardExternalCreateIntent) {
    match decision {
        TaskBoardExternalCreateBegin::Started(intent) => (true, intent),
        TaskBoardExternalCreateBegin::Existing(TaskBoardExternalCreateExisting::Recover(
            intent,
        )) => (false, intent),
        other => panic!("unexpected begin decision: {other:?}"),
    }
}

pub(super) fn create_evidence(
    intent: &TaskBoardExternalCreateIntent,
    external_id: &str,
    revision: &str,
) -> (ExternalCreateOutcome, crate::task_board::ExternalRef) {
    let reference = ExternalTaskRef::new(intent.provider, external_id)
        .with_url(format!("https://example.invalid/tasks/{external_id}"));
    let outcome = ExternalCreateOutcome {
        reference: reference.clone(),
        provider_revision: Some(revision.into()),
        provider_project_id: Some(intent.snapshot.provider_target.clone()),
    };
    let mut baseline = reference.into_core_ref();
    baseline.sync_state = Some(ExternalRefSyncState {
        title: Some(intent.snapshot.title.clone()),
        body: Some(intent.snapshot.body.clone()),
        status: Some(TaskBoardStatus::Backlog),
        project_id: Some(intent.snapshot.provider_target.clone()),
        updated_at: Some(revision.into()),
        synced_at: Some("2026-07-16T10:00:00Z".into()),
    });
    (outcome, baseline)
}

async fn assert_record_conflict(
    db: &AsyncDaemonDb,
    intent: &TaskBoardExternalCreateIntent,
    outcome: &ExternalCreateOutcome,
    baseline: &crate::task_board::ExternalRef,
) {
    let error = db
        .record_task_board_external_create_outcome(intent, outcome, baseline)
        .await
        .expect_err("mismatched evidence must fail");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
}

async fn assert_exact_json(
    db: &AsyncDaemonDb,
    intent: &TaskBoardExternalCreateIntent,
    outcome: &ExternalCreateOutcome,
    baseline: &crate::task_board::ExternalRef,
) {
    let stored = sqlx::query_as::<_, (String, String, String, String)>(
        "SELECT create_snapshot_json, changed_fields_json, outcome_json, external_ref_json
         FROM task_board_external_create_intents WHERE intent_id = ?1",
    )
    .bind(&intent.intent_id)
    .fetch_one(db.pool())
    .await
    .expect("stored JSON");
    assert_eq!(stored.0, serde_json::to_string(&intent.snapshot).unwrap());
    assert_eq!(
        stored.1,
        serde_json::to_string(&intent.changed_fields).unwrap()
    );
    assert_eq!(stored.2, serde_json::to_string(outcome).unwrap());
    assert_eq!(stored.3, serde_json::to_string(baseline).unwrap());
}

pub(super) async fn sequence(db: &AsyncDaemonDb) -> i64 {
    db.current_change_sequence().await.expect("change sequence")
}

pub(super) async fn assert_published(
    db: &AsyncDaemonDb,
    previous: i64,
    expected_scope: &str,
) -> i64 {
    let current = sequence(db).await;
    assert_eq!(current, previous + 1);
    assert_eq!(
        db.load_change_tracking_since(previous)
            .await
            .expect("published change"),
        vec![(expected_scope.to_owned(), current)]
    );
    current
}
