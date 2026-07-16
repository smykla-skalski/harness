use super::*;

#[tokio::test]
async fn no_baseline_workflow_status_push_records_canonical_backlog_truth() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "task-1".to_string(),
        "Local task".to_string(),
        String::new(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::InProgress;
    item.external_refs =
        vec![ExternalTaskRef::new(ExternalProvider::Todoist, "remote-1").into_core_ref()];
    board
        .create("Local task", "", item)
        .expect("create local task");
    let client = UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Status],
        Vec::new(),
    );
    let updates = client.updates.clone();
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Push,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(
        *updates.lock().expect("updates"),
        vec![("remote-1".to_string(), vec![ExternalSyncField::Status])]
    );
    assert_eq!(
        board.get("task-1").expect("updated task").external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::Backlog)
    );
}

#[tokio::test]
async fn remote_completion_does_not_reopen_an_active_workflow_lane() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    board
        .create(
            "Old title",
            "Old body",
            linked_item(
                "task-1",
                "Old title",
                "Old body",
                TaskBoardStatus::InProgress,
            ),
        )
        .expect("create local task");
    let client = UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Status],
        vec![remote_task(
            "remote-1",
            "Old title",
            "Old body",
            TaskBoardStatus::Done,
        )],
    );
    let updates = client.updates.clone();
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Both,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 1);
    assert_eq!(operations[0].action, ExternalSyncAction::Pull);
    assert!(updates.lock().expect("updates").is_empty());
    let updated = board.get("task-1").expect("updated task");
    assert_eq!(updated.status, TaskBoardStatus::InProgress);
    assert_eq!(
        updated.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::Done)
    );
}

#[tokio::test]
async fn local_todo_reopen_survives_pull_and_pushes_remote_open() {
    let temp = tempdir().expect("tempdir");
    let board = TaskBoardStore::new(temp.path().join("board"));
    let mut item = linked_item("task-1", "Old title", "Old body", TaskBoardStatus::Todo);
    item.external_refs[0]
        .sync_state
        .as_mut()
        .expect("sync state")
        .status = Some(TaskBoardStatus::Done);
    board
        .create("Old title", "Old body", item)
        .expect("create local task");
    let client = UpdateFakeSyncClient::new(
        ExternalProvider::Todoist,
        vec![ExternalSyncField::Status],
        vec![remote_task(
            "remote-1",
            "Old title",
            "Old body",
            TaskBoardStatus::Done,
        )],
    );
    let updates = client.updates.clone();
    let clients: Vec<Box<dyn ExternalSyncClient>> = vec![Box::new(client)];

    let operations = sync_external_tasks(
        &board,
        ExternalSyncOptions {
            provider: Some(ExternalProvider::Todoist),
            direction: ExternalSyncDirection::Both,
            conflict_policy: ExternalSyncConflictPolicy::Report,
            dry_run: false,
            status: None,
        },
        &clients,
    )
    .await
    .expect("sync external tasks");

    assert_eq!(operations.len(), 2);
    assert_eq!(operations[0].action, ExternalSyncAction::Pull);
    assert_eq!(operations[1].action, ExternalSyncAction::Push);
    assert_eq!(
        *updates.lock().expect("updates"),
        vec![("remote-1".to_string(), vec![ExternalSyncField::Status])]
    );
    let updated = board.get("task-1").expect("updated task");
    assert_eq!(updated.status, TaskBoardStatus::Todo);
    assert_eq!(
        updated.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::Backlog)
    );
}
