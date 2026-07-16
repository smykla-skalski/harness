use tempfile::tempdir;

use super::provider_external_creates_tests::{begin, connect, create_item, item, record};
use crate::task_board::{
    ExternalCreateOutcome, ExternalProvider, ExternalRef, ExternalRefSyncState, ExternalSyncField,
    ExternalTaskRef, TaskBoardExternalCreateBegin, TaskBoardExternalCreateFinalizeDisposition,
    TaskBoardExternalCreateIntent, TaskBoardStatus,
};

#[tokio::test]
async fn begin_derives_create_fields_from_the_atomic_snapshot() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    let cases = [
        (
            "github-todo-project",
            ExternalProvider::GitHub,
            TaskBoardStatus::Todo,
            Some("board-project"),
            "example/repository",
            vec![
                ExternalSyncField::Title,
                ExternalSyncField::Body,
                ExternalSyncField::Status,
            ],
        ),
        (
            "github-done-project",
            ExternalProvider::GitHub,
            TaskBoardStatus::Done,
            Some("board-project"),
            "example/repository",
            vec![ExternalSyncField::Title, ExternalSyncField::Body],
        ),
        (
            "todoist-todo-project",
            ExternalProvider::Todoist,
            TaskBoardStatus::Todo,
            Some("todoist-project"),
            "todoist-project",
            vec![
                ExternalSyncField::Title,
                ExternalSyncField::Body,
                ExternalSyncField::Status,
                ExternalSyncField::Project,
            ],
        ),
        (
            "todoist-done-project",
            ExternalProvider::Todoist,
            TaskBoardStatus::Done,
            Some("todoist-project"),
            "todoist-project",
            vec![
                ExternalSyncField::Title,
                ExternalSyncField::Body,
                ExternalSyncField::Project,
            ],
        ),
        (
            "todoist-todo-no-project",
            ExternalProvider::Todoist,
            TaskBoardStatus::Todo,
            None,
            "todoist-project",
            vec![
                ExternalSyncField::Title,
                ExternalSyncField::Body,
                ExternalSyncField::Status,
            ],
        ),
    ];
    for (item_id, provider, status, project_id, target, expected) in cases {
        let mut board_item = item(item_id);
        board_item.status = status;
        board_item.project_id = project_id.map(ToOwned::to_owned);
        create_item(&db, board_item).await;

        let intent = start(&db, item_id, provider, "scope", target).await;

        assert_eq!(intent.changed_fields, expected, "case {item_id}");
    }
}

#[tokio::test]
async fn create_key_lookup_tracks_every_durable_state() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-create-key-state")).await;
    let intent = begin(&db, "task-create-key-state", ExternalProvider::GitHub).await;

    assert_eq!(
        db.task_board_external_create_intent_by_create_key(
            ExternalProvider::GitHub,
            &intent.create_key,
        )
        .await
        .expect("lookup in-flight"),
        Some(intent.clone())
    );

    let created = record(&db, &intent, "example/repository#71").await;
    assert_eq!(
        db.task_board_external_create_intent_by_create_key(
            ExternalProvider::GitHub,
            &intent.create_key,
        )
        .await
        .expect("lookup created"),
        Some(created.clone())
    );

    let attached = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize intent")
        .intent;
    assert_eq!(
        db.task_board_external_create_intent_by_create_key(
            ExternalProvider::GitHub,
            &intent.create_key,
        )
        .await
        .expect("lookup attached"),
        Some(attached)
    );
}

#[tokio::test]
async fn create_key_identity_is_unique_within_provider_and_isolated_across_providers() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-key-github-owner")).await;
    create_item(&db, item("task-key-github-other")).await;
    let mut todoist = item("task-key-todoist");
    todoist.project_id = Some("todoist-project".into());
    create_item(&db, todoist).await;
    let github = begin(&db, "task-key-github-owner", ExternalProvider::GitHub).await;
    let github_other = begin(&db, "task-key-github-other", ExternalProvider::GitHub).await;
    let todoist = begin(&db, "task-key-todoist", ExternalProvider::Todoist).await;

    sqlx::query(
        "UPDATE task_board_external_create_intents SET create_key = ?1 WHERE intent_id = ?2",
    )
    .bind(&github.create_key)
    .bind(&todoist.intent_id)
    .execute(db.pool())
    .await
    .expect("reuse key for a different provider");
    let collision = sqlx::query(
        "UPDATE task_board_external_create_intents SET create_key = ?1 WHERE intent_id = ?2",
    )
    .bind(&github.create_key)
    .bind(&github_other.intent_id)
    .execute(db.pool())
    .await
    .expect_err("same-provider key collision must fail");

    assert!(collision.to_string().contains("UNIQUE"));
    assert_eq!(
        db.task_board_external_create_intent_by_create_key(
            ExternalProvider::GitHub,
            &github.create_key,
        )
        .await
        .expect("lookup GitHub key")
        .expect("GitHub intent")
        .item_id,
        github.item_id
    );
    assert_eq!(
        db.task_board_external_create_intent_by_create_key(
            ExternalProvider::Todoist,
            &github.create_key,
        )
        .await
        .expect("lookup Todoist key")
        .expect("Todoist intent")
        .item_id,
        todoist.item_id
    );
}

#[tokio::test]
async fn provider_wide_in_flight_recovery_is_scope_independent_and_deterministic() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    for item_id in ["task-inflight-a", "task-inflight-b", "task-inflight-c"] {
        create_item(&db, item(item_id)).await;
    }
    let mut todoist_item = item("task-inflight-todoist");
    todoist_item.project_id = Some("todoist-project".into());
    create_item(&db, todoist_item).await;
    let first = start(
        &db,
        "task-inflight-a",
        ExternalProvider::GitHub,
        "vanished-scope-a",
        "example/repository",
    )
    .await;
    let second = start(
        &db,
        "task-inflight-b",
        ExternalProvider::GitHub,
        "vanished-scope-b",
        "example/repository",
    )
    .await;
    let third = start(
        &db,
        "task-inflight-c",
        ExternalProvider::GitHub,
        "live-scope",
        "example/repository",
    )
    .await;
    let _todoist = begin(&db, "task-inflight-todoist", ExternalProvider::Todoist).await;
    let mut expected = vec![first.clone(), second.clone(), third.clone()];
    expected.sort_by(|left, right| {
        (&left.created_at, &left.intent_id).cmp(&(&right.created_at, &right.intent_id))
    });

    assert_eq!(
        db.list_in_flight_task_board_external_create_intents(ExternalProvider::GitHub)
            .await
            .expect("provider-wide in-flight recovery"),
        expected
    );

    let _created = record(&db, &first, "example/repository#72").await;
    let second = record(&db, &second, "example/repository#73").await;
    db.finalize_task_board_external_create_intent(&second)
        .await
        .expect("attach second intent");
    assert_eq!(
        db.list_in_flight_task_board_external_create_intents(ExternalProvider::GitHub)
            .await
            .expect("filtered provider-wide recovery"),
        vec![third]
    );
}

#[tokio::test]
async fn recovery_accepts_edited_closed_and_moved_todoist_evidence() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    let mut board_item = item("task-recovery-drift");
    board_item.project_id = Some("todoist-project".into());
    create_item(&db, board_item).await;
    let intent = begin(&db, "task-recovery-drift", ExternalProvider::Todoist).await;
    let (outcome, baseline) = current_todoist_evidence();

    let created = db
        .record_task_board_external_create_outcome(&intent, &outcome, &baseline)
        .await
        .expect("record drifted current provider task");
    let finalized = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize drifted provider task");

    assert_eq!(
        created
            .created_evidence()
            .expect("created evidence")
            .provider_baseline,
        baseline
    );
    assert_eq!(
        finalized.item.expect("linked item").project_id.as_deref(),
        Some("todoist-project-moved")
    );
}

#[tokio::test]
async fn recovery_accepts_a_github_issue_moved_from_the_original_repository() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-recovery-github-moved")).await;
    let intent = begin(&db, "task-recovery-github-moved", ExternalProvider::GitHub).await;
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "moved/repository#74")
        .with_url("https://example.invalid/issues/74");
    let outcome = ExternalCreateOutcome {
        reference: reference.clone(),
        provider_revision: Some("revision-moved".into()),
        provider_project_id: Some("moved/repository".into()),
    };
    let mut baseline = reference.into_core_ref();
    baseline.sync_state = Some(ExternalRefSyncState {
        title: Some("Edited GitHub title".into()),
        body: Some("Edited GitHub body".into()),
        status: Some(TaskBoardStatus::Done),
        project_id: Some("moved/repository".into()),
        updated_at: Some("revision-moved".into()),
        synced_at: Some("2026-07-16T14:56:00Z".into()),
    });

    let created = db
        .record_task_board_external_create_outcome(&intent, &outcome, &baseline)
        .await
        .expect("record moved GitHub issue");
    let finalized = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize moved GitHub issue");

    assert_eq!(
        finalized
            .item
            .expect("linked item")
            .execution_repository
            .as_deref(),
        Some("moved/repository")
    );
}

#[tokio::test]
async fn moved_github_recovery_accepts_an_already_converged_local_identity() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-recovery-github-converged")).await;
    let intent = begin(
        &db,
        "task-recovery-github-converged",
        ExternalProvider::GitHub,
    )
    .await;
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "moved/repository#75")
        .with_url("https://example.invalid/issues/75");
    let outcome = ExternalCreateOutcome {
        reference: reference.clone(),
        provider_revision: Some("revision-moved".into()),
        provider_project_id: Some("moved/repository".into()),
    };
    let mut baseline = reference.into_core_ref();
    baseline.sync_state = Some(ExternalRefSyncState {
        title: Some("Moved GitHub title".into()),
        body: Some("Moved GitHub body".into()),
        status: Some(TaskBoardStatus::Done),
        project_id: Some("moved/repository".into()),
        updated_at: Some("revision-moved".into()),
        synced_at: Some("2026-07-16T15:02:00Z".into()),
    });
    let created = db
        .record_task_board_external_create_outcome(&intent, &outcome, &baseline)
        .await
        .expect("record moved GitHub issue");
    db.update_task_board_item("task-recovery-github-converged", |current| {
        current.execution_repository = Some("moved/repository".into());
        current.external_refs.push(baseline.clone());
        Ok(true)
    })
    .await
    .expect("converge local GitHub identity");

    let finalized = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize converged GitHub identity");

    assert_eq!(
        finalized.disposition,
        TaskBoardExternalCreateFinalizeDisposition::AlreadyLinked
    );
    let linked = finalized.item.expect("linked item");
    assert_eq!(
        linked.execution_repository.as_deref(),
        Some("moved/repository")
    );
    assert_eq!(linked.external_refs, vec![baseline]);
}

#[tokio::test]
async fn recovery_rejects_incomplete_or_internally_inconsistent_evidence() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    let mut board_item = item("task-recovery-invalid");
    board_item.project_id = Some("todoist-project".into());
    create_item(&db, board_item).await;
    let intent = begin(&db, "task-recovery-invalid", ExternalProvider::Todoist).await;
    let (outcome, baseline) = current_todoist_evidence();
    let mut cases = Vec::new();

    let mut url = baseline.clone();
    url.url = Some("https://example.invalid/different".into());
    cases.push(("url", outcome.clone(), url));
    let mut project = baseline.clone();
    project.sync_state.as_mut().unwrap().project_id = Some("other-project".into());
    cases.push(("project", outcome.clone(), project));
    let mut revision = baseline.clone();
    revision.sync_state.as_mut().unwrap().updated_at = Some("other-revision".into());
    cases.push(("revision", outcome.clone(), revision));
    let mut provider = baseline.clone();
    provider.provider = ExternalProvider::GitHub.into();
    cases.push(("provider", outcome.clone(), provider));
    let mut identity = baseline.clone();
    identity.external_id = "different-task".into();
    cases.push(("identity", outcome.clone(), identity));
    let mut status = baseline.clone();
    status.sync_state.as_mut().unwrap().status = Some(TaskBoardStatus::InProgress);
    cases.push(("status-value", outcome.clone(), status));
    let mut synced_at = baseline.clone();
    synced_at.sync_state.as_mut().unwrap().synced_at = Some("invalid".into());
    cases.push(("synced-at-value", outcome.clone(), synced_at));
    for field in [
        "title",
        "body",
        "status",
        "project_id",
        "updated_at",
        "synced_at",
    ] {
        let mut incomplete = baseline.clone();
        clear_sync_field(incomplete.sync_state.as_mut().unwrap(), field);
        cases.push((field, outcome.clone(), incomplete));
    }

    for (case, outcome, baseline) in cases {
        let error = db
            .record_task_board_external_create_outcome(&intent, &outcome, &baseline)
            .await
            .expect_err("invalid recovery evidence must fail");
        assert_eq!(error.code(), "WORKFLOW_CONCURRENT", "case {case}");
    }
}

#[tokio::test]
async fn persisted_changed_fields_must_match_the_derived_create_contract() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-create-fields-corrupt")).await;
    let intent = begin(&db, "task-create-fields-corrupt", ExternalProvider::GitHub).await;
    sqlx::query(
        "UPDATE task_board_external_create_intents
         SET changed_fields_json = '[\"title\",\"body\"]'
         WHERE intent_id = ?1",
    )
    .bind(&intent.intent_id)
    .execute(db.pool())
    .await
    .expect("corrupt persisted create fields");

    let error = db
        .task_board_external_create_intent_by_create_key(
            ExternalProvider::GitHub,
            &intent.create_key,
        )
        .await
        .expect_err("stale create fields must fail closed");

    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
}

async fn start(
    db: &crate::daemon::db::AsyncDaemonDb,
    item_id: &str,
    provider: ExternalProvider,
    scope_id: &str,
    provider_target: &str,
) -> TaskBoardExternalCreateIntent {
    match db
        .begin_task_board_external_create_intent(item_id, provider, scope_id, provider_target)
        .await
        .expect("begin create intent")
    {
        TaskBoardExternalCreateBegin::Started(intent) => intent,
        other => panic!("expected started intent, got {other:?}"),
    }
}

fn current_todoist_evidence() -> (ExternalCreateOutcome, ExternalRef) {
    let reference = ExternalTaskRef::new(ExternalProvider::Todoist, "todoist-task-recovered")
        .with_url("https://example.invalid/tasks/todoist-task-recovered");
    let outcome = ExternalCreateOutcome {
        reference: reference.clone(),
        provider_revision: Some("revision-recovered".into()),
        provider_project_id: Some("todoist-project-moved".into()),
    };
    let mut baseline = reference.into_core_ref();
    baseline.sync_state = Some(ExternalRefSyncState {
        title: Some("Edited provider title".into()),
        body: Some("Edited provider body".into()),
        status: Some(TaskBoardStatus::Done),
        project_id: Some("todoist-project-moved".into()),
        updated_at: Some("revision-recovered".into()),
        synced_at: Some("2026-07-16T14:55:00Z".into()),
    });
    (outcome, baseline)
}

fn clear_sync_field(state: &mut ExternalRefSyncState, field: &str) {
    match field {
        "title" => state.title = None,
        "body" => state.body = None,
        "status" => state.status = None,
        "project_id" => state.project_id = None,
        "updated_at" => state.updated_at = None,
        "synced_at" => state.synced_at = None,
        _ => panic!("unknown sync field {field}"),
    }
}
