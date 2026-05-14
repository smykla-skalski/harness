use tempfile::tempdir;

use crate::task_board::store::{TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::types::{AgentMode, TaskBoardItem, TaskBoardStatus};

#[test]
fn create_get_list_update_delete_round_trips_markdown() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    let item = TaskBoardItem::new(
        "task-1".into(),
        "placeholder".into(),
        String::new(),
        "2026-05-14T00:00:00Z".into(),
    );

    let created = store
        .create("Ship board", "Implement the task board.", item)
        .expect("create item");
    assert_eq!(created.title, "Ship board");

    let loaded = store.get("task-1").expect("load item");
    assert_eq!(loaded.body, "Implement the task board.");
    assert_eq!(loaded.status, TaskBoardStatus::New);

    let updated = store
        .update(
            "task-1",
            TaskBoardItemPatch {
                status: Some(TaskBoardStatus::InProgress),
                agent_mode: Some(AgentMode::Interactive),
                tags: Some(vec!["monitor".into(), "cli".into()]),
                ..TaskBoardItemPatch::default()
            },
        )
        .expect("update item");
    assert_eq!(updated.status, TaskBoardStatus::InProgress);
    assert_eq!(updated.tags, ["monitor", "cli"]);

    let listed = store
        .list(Some(TaskBoardStatus::InProgress))
        .expect("list items");
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, "task-1");

    store.delete("task-1").expect("delete item");
    assert!(store.list(None).expect("list active").is_empty());
}

#[test]
fn create_rejects_duplicate_id() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    let item = TaskBoardItem::new(
        "task-1".into(),
        "Title".into(),
        String::new(),
        "2026-05-14T00:00:00Z".into(),
    );
    store.create("Title", "Body", item.clone()).expect("create");

    let err = store.create("Title", "Body", item).expect_err("duplicate");
    assert!(err.message().contains("already exists"));
}
