use super::{WorkerPromptContext, optional_facts, plan_worker_prompt, render_worker_prompt};
use crate::task_board::prompt_catalog::{
    prompt_catalog_test_lock, PromptCatalog, scoped_prompt_catalog,
};
use crate::task_board::{
    ExternalRef, ExternalRefProvider, TaskBoardItem, TaskBoardPriority, TaskBoardStatus,
};

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

/// `project_id_section` and `planning_summary_section` reached no golden, and a
/// hand-written list of sections would go stale the next time a fact lands. Walk
/// the renderer's own fact set instead, so a new fact fails here until the
/// fixture supplies it, and pin each section's bytes and its place in the order.
#[test]
fn every_optional_fact_renders_its_shipped_section_in_order() {
    let item = populated_item();
    let context = populated_context();

    let prompt = render_worker_prompt(&item, &context).expect("render worker prompt");

    let mut searched = 0;
    for fact in optional_facts(&item, &context) {
        let value = fact
            .value
            .unwrap_or_else(|| panic!("the fixture must populate {}", fact.name));
        let section = format!("\n\n{}:\n{value}", fact.section_title);
        let offset = prompt[searched..]
            .find(&section)
            .unwrap_or_else(|| panic!("{} is missing or out of order in:\n{prompt}", fact.name));
        searched += offset + section.len();
    }
}

fn populated_item() -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        "board-3".into(),
        "Full item".into(),
        "Implement the whole thing".into(),
        "2026-07-25T00:00:00Z".into(),
    );
    item.project_id = Some("project-7".into());
    item.tags = vec!["backend".into(), "urgent".into()];
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "example/harness#9".into(),
        url: Some("https://github.com/example/harness/pull/9".into()),
        sync_state: None,
    }];
    item.planning.summary = Some("Split the change in two".into());
    item
}

fn populated_context() -> WorkerPromptContext<'static> {
    WorkerPromptContext {
        board_item_id: "board-3",
        work_item_id: "task-3",
        worktree: Some("/tmp/full-worktree"),
        session_id: Some("session-full"),
        managed_run_id: Some("run-full"),
        status: TaskBoardStatus::InProgress,
    }
}

#[test]
fn a_configured_prompt_may_name_a_fact_the_item_has() {
    let _lock = prompt_catalog_test_lock();
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"worker": "Do {{ title }} ({{ priority }})"}"#)
            .expect("parse overrides"),
    );

    let prompt = render_worker_prompt(&bare_item(), &bare_context()).expect("render worker prompt");

    assert_eq!(prompt, "Do Bare item (Low)");
}

#[test]
fn the_dispatch_preview_shows_why_a_prompt_cannot_be_rendered() {
    let _lock = prompt_catalog_test_lock();
    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"worker": "Do {{ title }} for {{ project_id }}"}"#)
            .expect("parse overrides"),
    );

    let preview = plan_worker_prompt(&bare_item());

    assert!(preview.contains("project_id"), "preview: {preview}");
}
