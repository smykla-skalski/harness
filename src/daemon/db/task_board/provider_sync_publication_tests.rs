use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::external::ExternalProviderScopeAttemptDecision;
use crate::task_board::{
    ExternalProvider, ExternalRefProvider, TaskBoardConflictState, TaskBoardItem,
    TaskBoardSyncConflict,
};

use super::ORCHESTRATOR_CHANGE_SCOPE;

#[tokio::test]
async fn backoff_only_changes_publish_without_identical_recovery_churn() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    let before_failure = db
        .current_change_sequence()
        .await
        .expect("initial revision");

    let failure_attempt = begin_attempt(&db, "2026-07-16T10:00:00Z").await;
    db.complete_task_board_provider_scope_failure(&failure_attempt, "2026-07-16T10:00:00Z")
        .await
        .expect("record failure");
    let after_failure = assert_orchestrator_change(&db, before_failure).await;

    let recovery_attempt = begin_attempt(&db, "2026-07-16T10:00:31Z").await;
    db.complete_task_board_provider_scope_success(&recovery_attempt, None, "2026-07-16T10:00:31Z")
        .await
        .expect("record recovery");
    let after_recovery = assert_orchestrator_change(&db, after_failure).await;

    let repeat_attempt = begin_attempt(&db, "2026-07-16T10:01:00Z").await;
    db.complete_task_board_provider_scope_success(&repeat_attempt, None, "2026-07-16T10:01:00Z")
        .await
        .expect("repeat identical healthy state");
    assert_eq!(
        db.current_change_sequence().await.expect("stable revision"),
        after_recovery
    );
}

#[tokio::test]
async fn conflict_only_changes_publish_without_identical_write_churn() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("database");
    db.create_task_board_item(TaskBoardItem::new(
        "task-conflict-publication".into(),
        "Task".into(),
        String::new(),
        "2026-07-15T10:00:00Z".into(),
    ))
    .await
    .expect("create item");
    let item_revision = db
        .task_board_item_snapshot("task-conflict-publication")
        .await
        .expect("item snapshot")
        .item_revision;
    let before_conflict = db.current_change_sequence().await.expect("item revision");
    let mut conflict = conflict();

    db.replace_open_task_board_sync_conflicts(
        "task-conflict-publication",
        ExternalProvider::GitHub,
        "acme/widgets#17",
        item_revision,
        &[conflict.clone()],
    )
    .await
    .expect("create conflict");
    let after_create = assert_orchestrator_change(&db, before_conflict).await;

    db.replace_open_task_board_sync_conflicts(
        "task-conflict-publication",
        ExternalProvider::GitHub,
        "acme/widgets#17",
        item_revision,
        &[conflict.clone()],
    )
    .await
    .expect("repeat identical conflict");
    assert_eq!(
        db.current_change_sequence().await.expect("stable revision"),
        after_create
    );

    conflict.remote_value = serde_json::json!("updated remote");
    db.replace_open_task_board_sync_conflicts(
        "task-conflict-publication",
        ExternalProvider::GitHub,
        "acme/widgets#17",
        item_revision,
        &[conflict],
    )
    .await
    .expect("update conflict");
    let after_update = assert_orchestrator_change(&db, after_create).await;

    db.replace_open_task_board_sync_conflicts(
        "task-conflict-publication",
        ExternalProvider::GitHub,
        "acme/widgets#17",
        item_revision,
        &[],
    )
    .await
    .expect("supersede conflict");
    let after_supersede = assert_orchestrator_change(&db, after_update).await;
    assert_eq!(
        db.task_board_item_snapshot("task-conflict-publication")
            .await
            .expect("unchanged item snapshot")
            .item_revision,
        item_revision
    );

    db.replace_open_task_board_sync_conflicts(
        "task-conflict-publication",
        ExternalProvider::GitHub,
        "acme/widgets#17",
        item_revision,
        &[],
    )
    .await
    .expect("repeat empty conflict set");
    assert_eq!(
        db.current_change_sequence().await.expect("stable revision"),
        after_supersede
    );
}

async fn begin_attempt(
    db: &AsyncDaemonDb,
    now: &str,
) -> crate::task_board::external::ExternalProviderScopeAttempt {
    match db
        .begin_task_board_provider_scope_attempt(ExternalProvider::GitHub, "acme/widgets", now)
        .await
        .expect("begin provider attempt")
    {
        ExternalProviderScopeAttemptDecision::Started(attempt) => attempt,
        other => panic!("expected started attempt, got {other:?}"),
    }
}

async fn assert_orchestrator_change(db: &AsyncDaemonDb, previous: i64) -> i64 {
    let current = db
        .current_change_sequence()
        .await
        .expect("current revision");
    assert!(current > previous);
    assert!(
        db.load_change_tracking_since(previous)
            .await
            .expect("load changes")
            .iter()
            .any(|(scope, revision)| scope == ORCHESTRATOR_CHANGE_SCOPE && *revision == current)
    );
    current
}

fn conflict() -> TaskBoardSyncConflict {
    TaskBoardSyncConflict {
        conflict_id: "conflict-publication".into(),
        item_id: "task-conflict-publication".into(),
        provider: ExternalRefProvider::GitHub,
        external_ref: "acme/widgets#17".into(),
        field: "title".into(),
        base_value: serde_json::json!("base"),
        local_value: serde_json::json!("local"),
        remote_value: serde_json::json!("remote"),
        item_revision: 1,
        provider_revision: Some("provider-revision-1".into()),
        state: TaskBoardConflictState::Open,
    }
}
