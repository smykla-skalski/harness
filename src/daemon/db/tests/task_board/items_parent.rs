use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::TaskBoardItem;

async fn test_db() -> AsyncDaemonDb {
    let dir = tempdir().expect("tempdir");
    AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db")
}

fn new_item(id: &str) -> TaskBoardItem {
    TaskBoardItem::new(
        id.to_owned(),
        format!("Title {id}"),
        String::new(),
        "2026-07-21T10:00:00Z".to_owned(),
    )
}

#[tokio::test]
async fn set_parent_persists_and_survives_reconnect() {
    let dir = tempdir().expect("tempdir");
    let path = dir.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("open db");
    db.create_task_board_item(new_item("parent-a"))
        .await
        .expect("create parent");
    db.create_task_board_item(new_item("child-a"))
        .await
        .expect("create child");

    let updated = db
        .update_task_board_item("child-a", |item| {
            item.parent_item_id = Some("parent-a".to_owned());
            Ok(true)
        })
        .await
        .expect("set parent")
        .expect("mutation");
    assert_eq!(updated.item.parent_item_id.as_deref(), Some("parent-a"));
    assert_eq!(updated.item.child_order, 0);
    drop(db);

    let reopened = AsyncDaemonDb::connect(&path).await.expect("reopen db");
    let reloaded = reopened
        .task_board_item("child-a")
        .await
        .expect("reload child");
    assert_eq!(reloaded.parent_item_id.as_deref(), Some("parent-a"));
    assert_eq!(reloaded.child_order, 0);
}

#[tokio::test]
async fn item_with_no_parent_is_ordinary() {
    let db = test_db().await;
    let created = db
        .create_task_board_item(new_item("solo"))
        .await
        .expect("create item");
    assert_eq!(created.item.parent_item_id, None);
    assert_eq!(created.item.child_order, 0);
}

#[tokio::test]
async fn set_parent_rejects_self_parent() {
    let db = test_db().await;
    db.create_task_board_item(new_item("self-item"))
        .await
        .expect("create item");

    let error = db
        .update_task_board_item("self-item", |item| {
            item.parent_item_id = Some("self-item".to_owned());
            Ok(true)
        })
        .await
        .expect_err("self-parent must be rejected");
    assert!(error.to_string().contains("own parent"), "error: {error}");
}

#[tokio::test]
async fn set_parent_rejects_unknown_parent() {
    let db = test_db().await;
    db.create_task_board_item(new_item("orphan-candidate"))
        .await
        .expect("create item");

    let error = db
        .update_task_board_item("orphan-candidate", |item| {
            item.parent_item_id = Some("does-not-exist".to_owned());
            Ok(true)
        })
        .await
        .expect_err("unknown parent must be rejected");
    assert!(error.to_string().contains("not found"), "error: {error}");
}

#[tokio::test]
async fn set_parent_rejects_cycle() {
    let db = test_db().await;
    for id in ["a", "b", "c"] {
        db.create_task_board_item(new_item(id))
            .await
            .expect("create item");
    }
    db.update_task_board_item("b", |item| {
        item.parent_item_id = Some("a".to_owned());
        Ok(true)
    })
    .await
    .expect("set b's parent")
    .expect("mutation");
    db.update_task_board_item("c", |item| {
        item.parent_item_id = Some("b".to_owned());
        Ok(true)
    })
    .await
    .expect("set c's parent")
    .expect("mutation");

    let error = db
        .update_task_board_item("a", |item| {
            item.parent_item_id = Some("c".to_owned());
            Ok(true)
        })
        .await
        .expect_err("cycle must be rejected");
    assert!(error.to_string().contains("ancestor"), "error: {error}");

    let reloaded = db.task_board_item("a").await.expect("reload a");
    assert_eq!(reloaded.parent_item_id, None, "cycle must not be persisted");
}

#[tokio::test]
async fn children_keep_stable_append_order() {
    let db = test_db().await;
    db.create_task_board_item(new_item("parent"))
        .await
        .expect("create parent");
    for id in ["child-1", "child-2", "child-3"] {
        db.create_task_board_item(new_item(id))
            .await
            .expect("create child");
        db.update_task_board_item(id, |item| {
            item.parent_item_id = Some("parent".to_owned());
            Ok(true)
        })
        .await
        .expect("set parent")
        .expect("mutation");
    }

    let mut children: Vec<TaskBoardItem> = db
        .list_task_board_items(None)
        .await
        .expect("list items")
        .into_iter()
        .filter(|item| item.parent_item_id.as_deref() == Some("parent"))
        .collect();
    children.sort_by_key(|item| item.child_order);
    let ordered_ids: Vec<&str> = children.iter().map(|item| item.id.as_str()).collect();
    assert_eq!(ordered_ids, ["child-1", "child-2", "child-3"]);
    let orders: Vec<u32> = children.iter().map(|item| item.child_order).collect();
    assert_eq!(orders, [0, 1, 2]);
}

#[tokio::test]
async fn deleting_parent_unparents_children_without_deleting_them() {
    let db = test_db().await;
    db.create_task_board_item(new_item("parent-to-delete"))
        .await
        .expect("create parent");
    db.create_task_board_item(new_item("surviving-child"))
        .await
        .expect("create child");
    db.update_task_board_item("surviving-child", |item| {
        item.parent_item_id = Some("parent-to-delete".to_owned());
        Ok(true)
    })
    .await
    .expect("set parent")
    .expect("mutation");

    db.delete_task_board_item("parent-to-delete")
        .await
        .expect("delete parent");

    let child = db
        .task_board_item("surviving-child")
        .await
        .expect("reload child");
    assert_eq!(child.parent_item_id, None);
    assert!(!child.is_deleted());
    assert_eq!(child.child_order, 0);
}

#[tokio::test]
async fn clearing_parent_resets_child_order() {
    let db = test_db().await;
    db.create_task_board_item(new_item("parent-clear"))
        .await
        .expect("create parent");
    db.create_task_board_item(new_item("child-clear"))
        .await
        .expect("create child");
    db.update_task_board_item("child-clear", |item| {
        item.parent_item_id = Some("parent-clear".to_owned());
        Ok(true)
    })
    .await
    .expect("set parent")
    .expect("mutation");

    let cleared = db
        .update_task_board_item("child-clear", |item| {
            item.parent_item_id = None;
            Ok(true)
        })
        .await
        .expect("clear parent")
        .expect("mutation");
    assert_eq!(cleared.item.parent_item_id, None);
    assert_eq!(cleared.item.child_order, 0);
}
