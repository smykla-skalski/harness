use tempfile::tempdir;

use super::*;

#[tokio::test]
async fn external_sync_update_rejects_a_concurrent_local_edit() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
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

    let error = <AsyncDaemonDb as TaskBoardSyncStore>::update_item(
        &db,
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
