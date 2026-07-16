use fs_err as fs;
use tempfile::tempdir;

use crate::task_board::store::{TaskBoardItemPatch, TaskBoardStore};
use crate::task_board::types::TaskBoardStatus;

#[test]
fn legacy_markdown_umbrella_statuses_read_and_rewrite_as_backlog() {
    let temp = tempdir().expect("tempdir");
    let store = TaskBoardStore::new(temp.path().join("board"));
    let path = store.tasks_dir().join("legacy-umbrella.md");
    fs::create_dir_all(store.tasks_dir()).expect("create tasks dir");
    fs::write(
        &path,
        r#"---
schema_version: 1
id: legacy-umbrella
title: Legacy lane
status: umbrella
priority: medium
agent_mode: headless
external_refs:
- provider: github
  external_id: '42'
  sync_state:
    status: umbrella
created_at: 2026-05-14T00:00:00Z
updated_at: 2026-05-14T00:00:00Z
---

body
"#,
    )
    .expect("write legacy item");

    let loaded = store.get("legacy-umbrella").expect("read legacy item");
    assert_eq!(loaded.status, TaskBoardStatus::Backlog);
    assert_eq!(
        loaded.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::Backlog)
    );

    store
        .update(
            "legacy-umbrella",
            TaskBoardItemPatch {
                title: Some("Canonical lane".to_string()),
                ..TaskBoardItemPatch::default()
            },
        )
        .expect("rewrite legacy item");

    let contents = fs::read_to_string(path).expect("read canonical item");
    assert_eq!(contents.matches("status: backlog").count(), 2);
    assert!(!contents.contains("status: umbrella"));
}
