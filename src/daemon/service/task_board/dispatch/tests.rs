use super::*;
use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::types::TaskBoardItemKind;
use crate::task_board::{DispatchBlockReason, DispatchReadiness, MachineRegistry};
use tempfile::tempdir;

fn seed_umbrella(board: &TaskBoardStore, id: &str) {
    let mut item = TaskBoardItem::new(
        id.into(),
        id.into(),
        String::new(),
        "2026-05-15T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Todo;
    item.kind = TaskBoardItemKind::Umbrella;
    board.create(id, "", item).expect("create board item");
}

fn seed_item(board: &TaskBoardStore, id: &str, project_type: Option<&str>) {
    let mut item = TaskBoardItem::new(
        id.into(),
        id.into(),
        String::new(),
        "2026-05-15T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Todo;
    if let Some(project_type) = project_type {
        item.target_project_types = vec![project_type.into()];
    }
    board.create(id, "", item).expect("create board item");
}

fn seed_ready_item(board: &TaskBoardStore, id: &str) {
    let mut item = TaskBoardItem::new(
        id.into(),
        id.into(),
        String::new(),
        "2026-05-15T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Todo;
    let item = submit_plan(&item, "Plan summary").apply_to(&item);
    let item = approve_plan(&item, "lead", "2026-05-15T00:00:00Z").apply_to(&item);
    board.create(id, "", item).expect("create board item");
}

#[test]
fn dispatch_surfaces_machine_mismatch_for_other_project_types() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    let board = TaskBoardStore::new(root.clone());
    seed_item(&board, "matches", Some("web"));
    seed_item(&board, "mismatches", Some("data"));
    seed_item(&board, "wildcard", None);

    let registry = MachineRegistry::new(root.clone());
    let mut local = registry.ensure_local().expect("ensure local");
    local.project_types = vec!["web".into()];
    registry.upsert(&local).expect("declare project types");

    let response = dispatch_task_board(
        &TaskBoardDispatchRequest {
            item_id: None,
            status: Some(TaskBoardStatus::Todo),
            dry_run: true,
            project_dir: None,
            actor: None,
        },
        None,
        &board,
    )
    .expect("dispatch");

    let ids: Vec<&str> = response
        .plans
        .iter()
        .map(|plan| plan.board_item_id.as_str())
        .collect();
    assert!(ids.contains(&"matches"));
    assert!(ids.contains(&"wildcard"));
    assert!(ids.contains(&"mismatches"));

    let mismatched = response
        .plans
        .iter()
        .find(|plan| plan.board_item_id == "mismatches")
        .expect("mismatched plan present");
    match &mismatched.readiness {
        DispatchReadiness::Blocked {
            reason: DispatchBlockReason::MachineMismatch { required, declared },
        } => {
            assert_eq!(required, &vec!["data".to_string()]);
            assert_eq!(declared, &vec!["web".to_string()]);
        }
        other => panic!("expected machine_mismatch, got {other:?}"),
    }
}

#[test]
fn explicit_dispatch_of_an_umbrella_item_is_refused_with_a_typed_error() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    let board = TaskBoardStore::new(root);
    seed_umbrella(&board, "umbrella-1");

    let error = dispatch_task_board(
        &TaskBoardDispatchRequest {
            item_id: Some("umbrella-1".into()),
            status: None,
            dry_run: false,
            project_dir: None,
            actor: None,
        },
        None,
        &board,
    )
    .expect_err("an explicit umbrella dispatch must be refused, not silently no-op");

    assert_eq!(error.code(), "KSRCLI094");
}

#[test]
fn a_status_sweep_silently_skips_an_umbrella_item_without_erroring() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    let board = TaskBoardStore::new(root);
    seed_umbrella(&board, "umbrella-1");

    let response = dispatch_task_board(
        &TaskBoardDispatchRequest {
            item_id: None,
            status: Some(TaskBoardStatus::Todo),
            dry_run: false,
            project_dir: None,
            actor: None,
        },
        None,
        &board,
    )
    .expect("a status-driven sweep must not error just because it contains an umbrella");

    assert!(
        response.applied.is_empty(),
        "an umbrella can never become ready, so it can never be applied"
    );
    assert!(response.failures.is_empty(), "a skip is not a failure");
    match &response
        .plans
        .iter()
        .find(|plan| plan.board_item_id == "umbrella-1")
        .expect("umbrella plan present in the sweep")
        .readiness
    {
        DispatchReadiness::Blocked {
            reason: DispatchBlockReason::Kind { item_kind },
        } => assert_eq!(*item_kind, TaskBoardItemKind::Umbrella),
        other => panic!("expected a kind block, got {other:?}"),
    }
}

#[test]
fn dispatch_collects_per_plan_failures_without_short_circuit() {
    // Two ready plans, no project_dir on the request. Each plan tries to
    // create a session and fails on the missing project_dir gate; the loop
    // must surface both failures instead of bailing on the first.
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    let board = TaskBoardStore::new(root);
    seed_ready_item(&board, "ready-1");
    seed_ready_item(&board, "ready-2");

    let response = dispatch_task_board(
        &TaskBoardDispatchRequest {
            item_id: None,
            status: Some(TaskBoardStatus::Todo),
            dry_run: false,
            project_dir: None,
            actor: None,
        },
        None,
        &board,
    )
    .expect("dispatch should not short-circuit");

    assert!(
        response.applied.is_empty(),
        "no plan can succeed without project_dir; got applied: {:?}",
        response.applied
    );
    let failure_ids: Vec<&str> = response
        .failures
        .iter()
        .map(|failure| failure.board_item_id.as_str())
        .collect();
    assert!(failure_ids.contains(&"ready-1"));
    assert!(failure_ids.contains(&"ready-2"));
    for failure in &response.failures {
        assert_eq!(failure.kind, DispatchFailureKind::CreateSession);
        assert!(!failure.message.is_empty());
    }
}

#[test]
fn unlink_dispatched_item_clears_session_and_marks_workflow_failed() {
    let temp = tempdir().expect("tempdir");
    let root = temp.path().join("board");
    let board = TaskBoardStore::new(root);
    seed_ready_item(&board, "linked-1");

    // Simulate the link patch by directly applying the same write the
    // dispatch loop would have made; this avoids depending on a working
    // session creation path inside the test.
    let plan = build_dispatch_summary_with_policy_root(
        &[board.get("linked-1").expect("seed item")],
        board.root(),
    )
    .into_iter()
    .next()
    .expect("plan");
    let linked =
        link_dispatched_item(&board, &plan, "session-x", "work-x").expect("link dispatched item");
    assert_eq!(linked.status, TaskBoardStatus::InProgress);
    assert_eq!(linked.session_id.as_deref(), Some("session-x"));
    assert_eq!(linked.work_item_id.as_deref(), Some("work-x"));

    let undone = unlink_dispatched_item(&board, "linked-1", "worker spawn failed")
        .expect("unlink dispatched item");
    assert_eq!(undone.status, TaskBoardStatus::Todo);
    assert!(undone.session_id.is_none());
    assert!(undone.work_item_id.is_none());
    assert_eq!(undone.workflow.status, TaskBoardWorkflowStatus::Failed);
    assert_eq!(
        undone.workflow.last_error.as_deref(),
        Some("worker spawn failed")
    );
    assert_eq!(
        undone.workflow.current_step_id.as_deref(),
        Some("worker_spawn")
    );
}
