use tempfile::tempdir;

use super::ITEMS_CHANGE_SCOPE;
use super::provider_external_creates_tests::{
    assert_published, begin, connect, create_item, item, record, sequence,
};
use crate::task_board::{
    ExternalProvider, ExternalRefSyncState, ExternalTaskRef, TaskBoardExternalCreateBegin,
    TaskBoardExternalCreateExisting, TaskBoardExternalCreateFinalizeDisposition,
    TaskBoardExternalCreateIntentState, TaskBoardStatus,
};

#[tokio::test]
async fn finalize_attaches_latest_item_and_retains_receipt() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-finalize-latest")).await;
    let intent = begin(&db, "task-finalize-latest", ExternalProvider::GitHub).await;
    let created = record(&db, &intent, "example/repository#51").await;
    let baseline = created
        .created_evidence()
        .expect("created evidence")
        .provider_baseline
        .clone();
    db.update_task_board_item("task-finalize-latest", |current| {
        current.title = "Concurrent title".into();
        current.body = "Concurrent body".into();
        current.status = TaskBoardStatus::InProgress;
        current.project_id = Some("board-project".into());
        Ok(true)
    })
    .await
    .expect("concurrent edit");
    sqlx::query(
        "UPDATE task_board_items SET updated_at = '2999-01-01T00:00:00Z'
         WHERE item_id = 'task-finalize-latest'",
    )
    .execute(db.pool())
    .await
    .expect("seed newer item timestamp");
    let before = sequence(&db).await;

    let finalized = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize create");

    assert_eq!(
        finalized.disposition,
        TaskBoardExternalCreateFinalizeDisposition::Attached
    );
    assert_eq!(finalized.item_revision, Some(3));
    let linked = finalized.item.expect("linked item");
    assert_eq!(linked.title, "Concurrent title");
    assert_eq!(linked.body, "Concurrent body");
    assert_eq!(linked.status, TaskBoardStatus::InProgress);
    assert_eq!(linked.project_id.as_deref(), Some("board-project"));
    assert_eq!(
        linked.execution_repository.as_deref(),
        Some("example/repository")
    );
    assert_eq!(linked.external_refs, vec![baseline]);
    assert_eq!(linked.updated_at, "2999-01-01T00:00:00Z");
    assert_published(&db, before, ITEMS_CHANGE_SCOPE).await;
    assert!(
        db.task_board_external_create_intent("task-finalize-latest", ExternalProvider::GitHub,)
            .await
            .expect("active intent")
            .is_none()
    );
    let TaskBoardExternalCreateIntentState::Attached(receipt) = &finalized.intent.state else {
        panic!("finalization must retain an attached receipt");
    };
    assert!(receipt.attached_at > receipt.evidence.recorded_at);
}

#[tokio::test]
async fn attached_receipt_blocks_stale_finalize_and_new_create_after_unlink() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-finalize-stale")).await;
    let intent = begin(&db, "task-finalize-stale", ExternalProvider::GitHub).await;
    let created = record(&db, &intent, "example/repository#57").await;
    db.finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize create");
    db.update_task_board_item("task-finalize-stale", |current| {
        current.external_refs.clear();
        Ok(true)
    })
    .await
    .expect("unlink item");
    let before_stale = sequence(&db).await;
    let stale = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("stale finalize");
    assert_eq!(
        stale.disposition,
        TaskBoardExternalCreateFinalizeDisposition::AlreadyAttached
    );
    assert!(stale.item.is_none());
    assert_eq!(sequence(&db).await, before_stale);
    let begin_after_unlink = db
        .begin_task_board_external_create_intent(
            "task-finalize-stale",
            ExternalProvider::GitHub,
            "new-scope",
            "example/repository",
        )
        .await
        .expect("begin after unlink");
    assert!(matches!(
        begin_after_unlink,
        TaskBoardExternalCreateBegin::Existing(TaskBoardExternalCreateExisting::Attached(_))
    ));
    assert_eq!(sequence(&db).await, before_stale);

    let delete_error =
        sqlx::query("DELETE FROM task_board_items WHERE item_id = 'task-finalize-stale'")
            .execute(db.pool())
            .await
            .expect_err("attached receipt must restrict hard delete");
    assert!(delete_error.to_string().contains("FOREIGN KEY"));
}

#[tokio::test]
async fn finalize_same_identity_preserves_newer_local_reference() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-finalize-existing")).await;
    let intent = begin(&db, "task-finalize-existing", ExternalProvider::GitHub).await;
    let created = record(&db, &intent, "example/repository#52").await;
    let mut newer = ExternalTaskRef::new(ExternalProvider::GitHub, "example/repository#52")
        .with_url("https://example.invalid/newer")
        .into_core_ref();
    newer.sync_state = Some(ExternalRefSyncState {
        title: Some("Newer remote title".into()),
        body: Some("Newer remote body".into()),
        status: Some(TaskBoardStatus::Done),
        project_id: Some("example/repository".into()),
        updated_at: Some("revision-newer".into()),
        synced_at: Some("2026-07-16T11:00:00Z".into()),
        labels: Vec::new(),
    });
    db.update_task_board_item("task-finalize-existing", |current| {
        current.external_refs.push(newer.clone());
        Ok(true)
    })
    .await
    .expect("link newer reference");
    let before = sequence(&db).await;

    let finalized = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize existing identity");

    assert_eq!(
        finalized.disposition,
        TaskBoardExternalCreateFinalizeDisposition::AlreadyLinked
    );
    assert_eq!(finalized.item_revision, Some(3));
    let linked = finalized.item.expect("linked item");
    assert_eq!(linked.external_refs, vec![newer]);
    assert_eq!(
        linked.execution_repository.as_deref(),
        Some("example/repository")
    );
    assert_published(&db, before, ITEMS_CHANGE_SCOPE).await;
}

#[tokio::test]
async fn finalize_existing_todoist_identity_normalizes_provider_project() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-finalize-todoist-existing")).await;
    let intent = begin(
        &db,
        "task-finalize-todoist-existing",
        ExternalProvider::Todoist,
    )
    .await;
    let created = record(&db, &intent, "todoist-task-52").await;
    let baseline = created
        .created_evidence()
        .expect("created evidence")
        .provider_baseline
        .clone();
    db.update_task_board_item("task-finalize-todoist-existing", |current| {
        current.external_refs.push(baseline.clone());
        Ok(true)
    })
    .await
    .expect("link Todoist reference");
    let before = sequence(&db).await;

    let finalized = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize existing Todoist identity");

    assert_eq!(finalized.item_revision, Some(3));
    assert_eq!(
        finalized.item.expect("linked item").project_id.as_deref(),
        Some("todoist-project")
    );
    assert_published(&db, before, ITEMS_CHANGE_SCOPE).await;
}

#[tokio::test]
async fn finalize_rejects_cross_item_or_different_same_provider_identity() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-finalize-owner")).await;
    create_item(&db, item("task-finalize-other")).await;
    let intent = begin(&db, "task-finalize-owner", ExternalProvider::GitHub).await;
    let created = record(&db, &intent, "example/repository#53").await;
    db.update_task_board_item("task-finalize-other", |current| {
        current.external_refs.push(
            ExternalTaskRef::new(ExternalProvider::GitHub, "example/repository#53").into_core_ref(),
        );
        Ok(true)
    })
    .await
    .expect("link identity elsewhere");
    db.delete_task_board_item("task-finalize-other")
        .await
        .expect("tombstone identity owner");
    let before = sequence(&db).await;

    let cross_item = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect_err("cross-item identity must fail");
    assert_eq!(cross_item.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(sequence(&db).await, before);

    create_item(&db, item("task-finalize-different")).await;
    let intent = begin(&db, "task-finalize-different", ExternalProvider::GitHub).await;
    let created = record(&db, &intent, "example/repository#54").await;
    db.update_task_board_item("task-finalize-different", |current| {
        current.external_refs.push(
            ExternalTaskRef::new(ExternalProvider::GitHub, "example/repository#99").into_core_ref(),
        );
        Ok(true)
    })
    .await
    .expect("link different provider identity");
    let before_different = sequence(&db).await;
    let different = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect_err("different provider identity must fail");
    assert_eq!(different.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(sequence(&db).await, before_different);
    assert_eq!(
        db.task_board_external_create_intent("task-finalize-different", ExternalProvider::GitHub,)
            .await
            .expect("retained created intent"),
        Some(created)
    );
}

#[tokio::test]
async fn attached_receipt_reserves_provider_identity_after_unlink() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-finalize-receipt-owner")).await;
    let owner = begin(&db, "task-finalize-receipt-owner", ExternalProvider::GitHub).await;
    let owner = record(&db, &owner, "example/repository#58").await;
    db.finalize_task_board_external_create_intent(&owner)
        .await
        .expect("attach owner");
    db.update_task_board_item("task-finalize-receipt-owner", |current| {
        current.external_refs.clear();
        Ok(true)
    })
    .await
    .expect("unlink owner");

    create_item(&db, item("task-finalize-receipt-other")).await;
    let other = begin(&db, "task-finalize-receipt-other", ExternalProvider::GitHub).await;
    let other = record(&db, &other, "example/repository#58").await;
    let before = sequence(&db).await;
    let error = db
        .finalize_task_board_external_create_intent(&other)
        .await
        .expect_err("attached receipt must reserve provider identity");

    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(sequence(&db).await, before);
    assert_eq!(
        db.task_board_external_create_intent(
            "task-finalize-receipt-other",
            ExternalProvider::GitHub,
        )
        .await
        .expect("retained created evidence"),
        Some(other)
    );
}

#[tokio::test]
async fn finalize_accepts_concurrent_github_target_normalization() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-finalize-github-normalized")).await;
    let intent = begin(
        &db,
        "task-finalize-github-normalized",
        ExternalProvider::GitHub,
    )
    .await;
    let created = record(&db, &intent, "example/repository#59").await;
    db.update_task_board_item("task-finalize-github-normalized", |current| {
        current.execution_repository = Some("example/repository".into());
        Ok(true)
    })
    .await
    .expect("normalize GitHub target");

    let finalized = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize normalized GitHub target");

    assert_eq!(
        finalized.disposition,
        TaskBoardExternalCreateFinalizeDisposition::Attached
    );
    assert_eq!(
        finalized
            .item
            .expect("linked item")
            .execution_repository
            .as_deref(),
        Some("example/repository")
    );
}

#[tokio::test]
async fn finalize_fails_on_github_target_divergence_but_preserves_todoist_project_edit() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-finalize-github-target")).await;
    let github = begin(&db, "task-finalize-github-target", ExternalProvider::GitHub).await;
    let github = record(&db, &github, "example/repository#55").await;
    db.update_task_board_item("task-finalize-github-target", |current| {
        current.execution_repository = Some("other/repository".into());
        Ok(true)
    })
    .await
    .expect("change GitHub target");
    let before_github = sequence(&db).await;
    let github_error = db
        .finalize_task_board_external_create_intent(&github)
        .await
        .expect_err("GitHub target divergence must fail");
    assert_eq!(github_error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(sequence(&db).await, before_github);

    let mut todoist_item = item("task-finalize-todoist-target");
    todoist_item.project_id = Some("todoist-project".into());
    create_item(&db, todoist_item).await;
    let todoist = begin(
        &db,
        "task-finalize-todoist-target",
        ExternalProvider::Todoist,
    )
    .await;
    let todoist = record(&db, &todoist, "todoist-task-55").await;
    db.update_task_board_item("task-finalize-todoist-target", |current| {
        current.project_id = Some("todoist-project-concurrent".into());
        Ok(true)
    })
    .await
    .expect("change Todoist project");
    let finalized = db
        .finalize_task_board_external_create_intent(&todoist)
        .await
        .expect("finalize Todoist target");
    assert_eq!(
        finalized.item.expect("Todoist item").project_id.as_deref(),
        Some("todoist-project-concurrent")
    );
}

#[tokio::test]
async fn tombstone_after_create_keeps_ref_attached_for_remote_cleanup() {
    let dir = tempdir().expect("tempdir");
    let db = connect(&dir).await;
    create_item(&db, item("task-finalize-tombstone")).await;
    let intent = begin(&db, "task-finalize-tombstone", ExternalProvider::GitHub).await;
    db.delete_task_board_item("task-finalize-tombstone")
        .await
        .expect("tombstone item");
    let created = record(&db, &intent, "example/repository#56").await;

    let finalized = db
        .finalize_task_board_external_create_intent(&created)
        .await
        .expect("finalize tombstone");
    let item = finalized.item.expect("tombstoned linked item");

    assert!(item.deleted_at.is_some());
    assert_eq!(item.external_refs.len(), 1);
    assert_eq!(
        finalized.disposition,
        TaskBoardExternalCreateFinalizeDisposition::Attached
    );
}
