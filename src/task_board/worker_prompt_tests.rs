use super::{WorkerPromptContext, plan_worker_prompt, render_worker_prompt};
use crate::task_board::prompt_catalog::{
    PROMPT_CATALOG_TEST_LOCK, PromptCatalog, scoped_prompt_catalog,
};
use crate::task_board::{TaskBoardItem, TaskBoardPriority, TaskBoardStatus};

/// Byte-for-byte what `render_worker_prompt` produced for an item with none of
/// the optional sections and no session to report into.
const BARE_GOLDEN: &str = "Work on task-board item 'Bare item'.\n\nBoard item: board-2\nSession task: task-2\nPriority: Low\nStatus: Todo\n\nLifecycle:\nImplement the requested work, keep changes scoped, and run the smallest relevant validation. Submit the task for review when ready.";

fn bare_item() -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        "board-2".into(),
        "Bare item".into(),
        "   ".into(),
        "2026-07-24T00:00:00Z".into(),
    );
    item.priority = TaskBoardPriority::Low;
    item
}

fn bare_context() -> WorkerPromptContext<'static> {
    WorkerPromptContext {
        board_item_id: "board-2",
        work_item_id: "task-2",
        worktree: None,
        session_id: None,
        managed_run_id: None,
        status: TaskBoardStatus::Todo,
    }
}

#[test]
fn plan_prompt_preserves_existing_session_checkout_and_marks_reserved_ids() {
    let mut item = TaskBoardItem::new(
        "board-1".into(),
        "Existing session task".into(),
        "Implement it".into(),
        "2026-07-13T00:00:00Z".into(),
    );
    item.session_id = Some("session-existing".into());
    item.workflow.worktree = Some("/tmp/existing-worktree".into());

    let prompt = plan_worker_prompt(&item);

    assert!(prompt.contains("Session id:\nsession-existing"));
    assert!(prompt.contains("Worktree:\n/tmp/existing-worktree"));
    assert!(prompt.contains("Session task: <assigned-at-dispatch>"));
    assert!(prompt.contains("Managed run id:\n<assigned-at-dispatch>"));
}

#[test]
fn an_item_without_optional_facts_renders_the_shipped_bytes() {
    let prompt = render_worker_prompt(&bare_item(), &bare_context()).expect("render worker prompt");

    assert_eq!(prompt, BARE_GOLDEN);
}

#[test]
fn a_configured_prompt_may_name_a_fact_the_item_has() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"worker": "Do {{ title }} ({{ priority }})"}"#)
            .expect("parse overrides"),
    );

    let prompt = render_worker_prompt(&bare_item(), &bare_context()).expect("render worker prompt");

    assert_eq!(prompt, "Do Bare item (Low)");
}

#[test]
fn the_dispatch_preview_shows_why_a_prompt_cannot_be_rendered() {
    let _lock = PROMPT_CATALOG_TEST_LOCK.lock().expect("catalog test lock");
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"worker": "Do {{ title }} for {{ project_id }}"}"#)
            .expect("parse overrides"),
    );

    let preview = plan_worker_prompt(&bare_item());

    assert!(preview.contains("project_id"), "preview: {preview}");
}
