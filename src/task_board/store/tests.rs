use tempfile::tempdir;

use crate::task_board::store::{TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::types::{
    AgentMode, PlanningState, TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus,
};

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
fn update_clears_links_planning_and_workflow() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "task-1".into(),
        "Linked".into(),
        String::new(),
        "2026-05-14T00:00:00Z".into(),
    );
    item.project_id = Some("project-1".into());
    item.session_id = Some("session-1".into());
    item.work_item_id = Some("work-1".into());
    item.planning.summary = Some("Plan".into());
    item.workflow.status = TaskBoardWorkflowStatus::Running;
    item.workflow.branch = Some("feature/task-1".into());
    store.create("Linked", "", item).expect("create");

    let updated = store
        .update(
            "task-1",
            TaskBoardItemPatch {
                project_id: super::OptionalFieldPatch::Clear,
                session_id: super::OptionalFieldPatch::Clear,
                work_item_id: super::OptionalFieldPatch::Clear,
                clear_planning: true,
                clear_workflow: true,
                ..TaskBoardItemPatch::default()
            },
        )
        .expect("update item");

    assert!(updated.project_id.is_none());
    assert!(updated.session_id.is_none());
    assert!(updated.work_item_id.is_none());
    assert_eq!(updated.planning, PlanningState::default());
    assert!(updated.workflow.is_default());
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

#[test]
fn revoke_approval_preserves_summary() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "task-1".into(),
        "Plan".into(),
        String::new(),
        "2026-05-14T00:00:00Z".into(),
    );
    item.planning.summary = Some("Use the reviewed plan".into());
    item.planning.approved_by = Some("lead".into());
    item.planning.approved_at = Some("2026-05-14T01:00:00Z".into());
    item.status = TaskBoardStatus::Todo;
    store.create("Plan", "", item).expect("create");

    let revoked = store
        .update(
            "task-1",
            TaskBoardItemPatch {
                status: Some(TaskBoardStatus::PlanReview),
                clear_approval: true,
                ..TaskBoardItemPatch::default()
            },
        )
        .expect("update item");

    assert_eq!(revoked.status, TaskBoardStatus::PlanReview);
    assert_eq!(
        revoked.planning.summary.as_deref(),
        Some("Use the reviewed plan")
    );
    assert_eq!(revoked.planning.approved_by, None);
    assert_eq!(revoked.planning.approved_at, None);
}

#[test]
fn update_with_approver_only_preserves_planning_summary() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    let mut item = TaskBoardItem::new(
        "task-1".into(),
        "Plan".into(),
        String::new(),
        "2026-05-14T00:00:00Z".into(),
    );
    item.planning.summary = Some("Keep this plan".into());
    store.create("Plan", "", item).expect("create");

    let updated = store
        .update(
            "task-1",
            TaskBoardItemPatch {
                planning: Some(PlanningState {
                    summary: None,
                    approved_by: Some("lead".into()),
                    approved_at: Some("2026-05-14T01:00:00Z".into()),
                }),
                ..TaskBoardItemPatch::default()
            },
        )
        .expect("update item");

    assert_eq!(updated.planning.summary.as_deref(), Some("Keep this plan"));
    assert_eq!(updated.planning.approved_by.as_deref(), Some("lead"));
    assert_eq!(
        updated.planning.approved_at.as_deref(),
        Some("2026-05-14T01:00:00Z")
    );
}
