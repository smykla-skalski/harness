use tempfile::tempdir;

use super::parse_cache::ParseCache;
use crate::task_board::store::{TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::types::{
    AgentMode, PlanningState, TaskBoardItem, TaskBoardPriority, TaskBoardStatus,
    TaskBoardWorkflowStatus,
};
use fs_err as fs;

fn seed_item(store: &TaskBoardStore, id: &str, title: &str) {
    let item = TaskBoardItem::new(
        id.into(),
        title.into(),
        String::new(),
        "2026-05-14T00:00:00Z".into(),
    );
    store.create(title, "body", item).expect("create item");
}

#[test]
fn parse_cache_skips_reparse_for_unchanged_files() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    for index in 0..3 {
        seed_item(&store, &format!("task-{index}"), &format!("Task {index}"));
    }
    let paths: Vec<_> = (0..3)
        .map(|index| store.tasks_dir().join(format!("task-{index}.md")))
        .collect();

    let cache = ParseCache::new();
    for path in &paths {
        cache.read(path).expect("first read");
    }
    assert_eq!(cache.parse_count(), 3, "cold reads parse every file once");

    for path in &paths {
        cache.read(path).expect("second read");
    }
    assert_eq!(
        cache.parse_count(),
        3,
        "unchanged files are served from cache without reparsing"
    );
}

#[test]
fn parse_cache_reparses_after_file_changes() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    seed_item(&store, "task-0", "Task 0");
    let path = store.tasks_dir().join("task-0.md");

    let cache = ParseCache::new();
    cache.read(&path).expect("cold read");
    assert_eq!(cache.parse_count(), 1);

    store
        .update(
            "task-0",
            TaskBoardItemPatch {
                status: Some(TaskBoardStatus::InProgress),
                ..TaskBoardItemPatch::default()
            },
        )
        .expect("update item");

    let reparsed = cache.read(&path).expect("warm read after change");
    assert_eq!(cache.parse_count(), 2, "changed mtime forces a reparse");
    assert_eq!(reparsed.status, TaskBoardStatus::InProgress);
}

#[test]
fn get_repairs_legacy_status_on_disk() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    let path = seed_raw_item(&store, "legacy-new", "new");

    let loaded = store.get("legacy-new").expect("load legacy item");

    assert_eq!(loaded.status, TaskBoardStatus::Todo);
    let contents = fs::read_to_string(path).expect("read repaired file");
    assert!(contents.contains("status: todo"));
    assert!(!contents.contains("status: new"));
}

#[test]
fn get_repair_reloads_a_newer_item_before_persisting() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    let path = seed_raw_item(&store, "repair-race", "new");
    let stale = super::read_path(&path).expect("read stale item");
    write_raw_item(&path, "repair-race", "Concurrent edit", "in_progress");

    let loaded = store
        .finish_get("repair-race", stale)
        .expect("finish legacy repair");

    assert_eq!(loaded.title, "Concurrent edit");
    assert_eq!(loaded.status, TaskBoardStatus::InProgress);
    let contents = fs::read_to_string(path).expect("read latest file");
    assert!(contents.contains("title: Concurrent edit"));
    assert!(contents.contains("status: in_progress"));
    assert!(!contents.contains("status: todo"));
}

#[test]
fn get_rejects_mismatched_frontmatter_id_before_repair() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    let path = seed_raw_item_with_frontmatter_id(&store, "file-id", "frontmatter-id", "new");

    let error = store.get("file-id").expect_err("mismatched id must fail");

    assert!(
        error
            .to_string()
            .contains("expected 'file-id', found 'frontmatter-id'")
    );
    assert!(
        !store.tasks_dir().join("frontmatter-id.md").exists(),
        "repair must not create a second file from frontmatter id"
    );
    let contents = fs::read_to_string(path).expect("read source file");
    assert!(contents.contains("status: new"));
    assert!(!contents.contains("status: todo"));
}

#[test]
fn list_repairs_legacy_statuses_before_filtering() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    seed_raw_item(&store, "legacy-needs-you", "needs_you");

    let listed = store
        .list(Some(TaskBoardStatus::HumanRequired))
        .expect("list repaired status");

    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, "legacy-needs-you");
    assert_eq!(listed[0].status, TaskBoardStatus::HumanRequired);
}

#[test]
fn list_repair_reloads_newer_items_before_persisting() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    let path = seed_raw_item(&store, "list-repair-race", "needs_you");
    let stale = super::read_path(&path).expect("read stale item");
    write_raw_item(
        &path,
        "list-repair-race",
        "Concurrent list edit",
        "in_progress",
    );

    let loaded = store
        .finish_read_all_items(vec![(path.clone(), stale)])
        .expect("finish list repair");

    assert_eq!(loaded.len(), 1);
    assert_eq!(loaded[0].title, "Concurrent list edit");
    assert_eq!(loaded[0].status, TaskBoardStatus::InProgress);
    let contents = fs::read_to_string(path).expect("read latest file");
    assert!(contents.contains("title: Concurrent list edit"));
    assert!(contents.contains("status: in_progress"));
    assert!(!contents.contains("status: human_required"));
}

#[test]
fn list_repairs_mismatched_frontmatter_id_at_source_path() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    let source =
        seed_raw_item_with_frontmatter_id(&store, "source-file", "frontmatter-id", "needs_you");

    let listed = store
        .list(Some(TaskBoardStatus::HumanRequired))
        .expect("list repaired status");

    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, "frontmatter-id");
    assert_eq!(listed[0].status, TaskBoardStatus::HumanRequired);
    let contents = fs::read_to_string(source).expect("read repaired source file");
    assert!(contents.contains("status: human_required"));
    assert!(!contents.contains("status: needs_you"));
    assert!(
        !store.tasks_dir().join("frontmatter-id.md").exists(),
        "list repair must write the original path, not the frontmatter id path"
    );
}

#[test]
fn list_maps_legacy_status_filter_to_current_status() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    seed_raw_item(&store, "legacy-blocked", "blocked");

    let listed = store
        .list(Some(TaskBoardStatus::Blocked))
        .expect("list legacy filter");

    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].id, "legacy-blocked");
    assert_eq!(listed[0].status, TaskBoardStatus::Failed);
}

#[test]
fn update_writes_current_status_for_legacy_status_patch() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    seed_item(&store, "task-0", "Task 0");

    let updated = store
        .update(
            "task-0",
            TaskBoardItemPatch {
                status: Some(TaskBoardStatus::PlanReview),
                ..TaskBoardItemPatch::default()
            },
        )
        .expect("update item");

    assert_eq!(updated.status, TaskBoardStatus::AgenticReview);
    let contents =
        fs::read_to_string(store.tasks_dir().join("task-0.md")).expect("read current status file");
    assert!(contents.contains("status: agentic_review"));
    assert!(!contents.contains("status: plan_review"));
}

#[test]
fn list_keeps_filter_and_sort_across_parallel_parse() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    for index in 0..6 {
        let mut item = TaskBoardItem::new(
            format!("task-{index}"),
            format!("Task {index}"),
            String::new(),
            "2026-05-14T00:00:00Z".into(),
        );
        item.status = if index % 2 == 0 {
            TaskBoardStatus::InProgress
        } else {
            TaskBoardStatus::Umbrella
        };
        item.priority = TaskBoardPriority::High;
        store
            .create(&item.title.clone(), "body", item)
            .expect("create");
    }

    let in_progress = store
        .list(Some(TaskBoardStatus::InProgress))
        .expect("filtered list");
    assert_eq!(in_progress.len(), 3);
    assert!(
        in_progress
            .iter()
            .all(|item| item.status == TaskBoardStatus::InProgress)
    );

    let all = store.list(None).expect("active list");
    assert_eq!(all.len(), 6);
    let mut sorted = all.clone();
    super::sort_items(&mut sorted);
    assert_eq!(
        all, sorted,
        "list output is already sorted regardless of parse order"
    );
}

fn seed_raw_item(store: &TaskBoardStore, id: &str, status: &str) -> std::path::PathBuf {
    seed_raw_item_with_frontmatter_id(store, id, id, status)
}

fn seed_raw_item_with_frontmatter_id(
    store: &TaskBoardStore,
    filename_id: &str,
    frontmatter_id: &str,
    status: &str,
) -> std::path::PathBuf {
    let path = store.tasks_dir().join(format!("{filename_id}.md"));
    fs::create_dir_all(store.tasks_dir()).expect("create tasks dir");
    write_raw_item(&path, frontmatter_id, "Legacy status", status);
    path
}

fn write_raw_item(path: &std::path::Path, frontmatter_id: &str, title: &str, status: &str) {
    fs::write(
        path,
        format!(
            "---\n\
             schema_version: 1\n\
             id: {frontmatter_id}\n\
             title: {title}\n\
             status: {status}\n\
             priority: medium\n\
             agent_mode: headless\n\
             created_at: 2026-05-14T00:00:00Z\n\
             updated_at: 2026-05-14T00:00:00Z\n\
             ---\n\n\
             body\n"
        ),
    )
    .expect("write raw item");
}

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
    assert_eq!(loaded.status, TaskBoardStatus::Todo);

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
                status: Some(TaskBoardStatus::AgenticReview),
                clear_approval: true,
                ..TaskBoardItemPatch::default()
            },
        )
        .expect("update item");

    assert_eq!(revoked.status, TaskBoardStatus::AgenticReview);
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
