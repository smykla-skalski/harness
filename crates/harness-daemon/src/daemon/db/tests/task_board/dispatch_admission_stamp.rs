use std::collections::HashMap;

use tempfile::tempdir;

use crate::daemon::db::task_board::write_workflow_fixture::{
    approved_write_item, complete_write_preparation,
};
use crate::daemon::db::{AsyncDaemonDb, ReservedTaskBoardDispatch};
use crate::task_board::{
    TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowStatus, build_dispatch_plans_with_policy,
};

#[tokio::test]
async fn task_board_dispatch_reservation_precedes_links_and_is_reclaimable() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    db.create_task_board_item(approved_write_item(TaskBoardItem::new(
        "task-dispatch-reserved".to_owned(),
        "Reserved dispatch".to_owned(),
        "Body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    )))
    .await
    .expect("create item");
    let item = db
        .task_board_item("task-dispatch-reserved")
        .await
        .expect("load item");
    let plan = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    let first = db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("reserve dispatch");
    let (intent_id, preparation) = match first {
        ReservedTaskBoardDispatch::Preparing {
            intent_id,
            preparation,
        } => (intent_id, preparation),
        ReservedTaskBoardDispatch::Applied(_) => panic!("new reservation was already applied"),
        ReservedTaskBoardDispatch::Blocked(_) => panic!("default admission blocked reservation"),
    };
    assert_eq!(preparation.board_item_id, "task-dispatch-reserved");
    let still_todo = db
        .task_board_item("task-dispatch-reserved")
        .await
        .expect("load reserved item");
    assert_eq!(still_todo.status, TaskBoardStatus::Todo);
    assert!(still_todo.session_id.is_none());
    assert!(still_todo.work_item_id.is_none());
    // The admit window is no longer a blind spot: the ticket exposes exactly the
    // execution that owns it while it waits in Todo.
    assert_eq!(
        still_todo.workflow.execution_id.as_deref(),
        Some(preparation.workflow_execution_id.as_str()),
        "a reserved ticket must expose its owning execution while still in Todo"
    );
    assert_eq!(
        still_todo.workflow.status,
        TaskBoardWorkflowStatus::Admitting
    );

    let repeated = db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("repeat reservation");
    assert!(matches!(
        repeated,
        ReservedTaskBoardDispatch::Preparing {
            intent_id: ref repeated_id,
            ..
        } if repeated_id == &intent_id
    ));
    // A repeated admission is a visible no-op: the ticket still owns exactly the
    // first execution rather than a second competing one.
    let after_repeat = db
        .task_board_item("task-dispatch-reserved")
        .await
        .expect("reload reserved item");
    assert_eq!(
        after_repeat.workflow.execution_id.as_deref(),
        Some(preparation.workflow_execution_id.as_str()),
        "a repeated admission must not re-stamp a different execution"
    );

    let claim = db
        .claim_task_board_dispatch_preparation(&intent_id)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    sqlx::query(
        "UPDATE task_board_dispatch_intents SET claimed_at = '1970-01-01T00:00:00Z'
         WHERE intent_id = ?1",
    )
    .bind(&intent_id)
    .execute(db.pool())
    .await
    .expect("age preparation before heartbeat");
    db.renew_task_board_dispatch_preparation(&claim)
        .await
        .expect("renew preparation claim");
    assert!(
        db.claim_next_task_board_dispatch_preparation()
            .await
            .expect("check renewed preparation")
            .is_none(),
        "a live preparation heartbeat must prevent concurrent reclamation"
    );
    sqlx::query(
        "UPDATE task_board_dispatch_intents SET claimed_at = '1970-01-01T00:00:00Z'
         WHERE intent_id = ?1",
    )
    .bind(&intent_id)
    .execute(db.pool())
    .await
    .expect("expire preparation");
    let reclaimed = db
        .claim_next_task_board_dispatch_preparation()
        .await
        .expect("reclaim preparation")
        .expect("expired preparation");
    assert_ne!(reclaimed.claim_token, claim.claim_token);
    let applied = complete_write_preparation(
        &db,
        &reclaimed,
        "harness/session-reserved",
        "/tmp/session-reserved",
    )
    .await
    .expect("complete preparation");
    assert_eq!(applied.item.status, TaskBoardStatus::InProgress);
    assert_eq!(
        applied.item.workflow.execution_id.as_deref(),
        Some(preparation.workflow_execution_id.as_str())
    );
    assert!(
        db.claim_task_board_dispatch("task-dispatch-reserved")
            .await
            .expect("claim worker")
            .is_some()
    );
}

#[tokio::test]
async fn admitting_stamp_clears_a_prior_execution_launch_data() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    db.create_task_board_item(approved_write_item(TaskBoardItem::new(
        "task-readmit".to_owned(),
        "Re-admit".to_owned(),
        "Body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    )))
    .await
    .expect("create item");
    // A dispatch that ran and was rolled back to Todo leaves its branch, worktree,
    // and step on the ticket. Seed that stale launch data so the re-admission has
    // something to clear.
    db.update_task_board_item("task-readmit", |item| {
        item.workflow.branch = Some("harness/dead-run".to_owned());
        item.workflow.worktree = Some("/tmp/dead-run".to_owned());
        item.workflow.current_step_id = Some("dispatch".to_owned());
        Ok(true)
    })
    .await
    .expect("seed stale launch data");

    let plan = build_dispatch_plans_with_policy(
        &[db.task_board_item("task-readmit").await.expect("load item")],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    db.reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("reserve dispatch");

    let admitted = db
        .task_board_item("task-readmit")
        .await
        .expect("load readmitted item");
    assert_eq!(admitted.workflow.status, TaskBoardWorkflowStatus::Admitting);
    assert!(
        admitted.workflow.branch.is_none()
            && admitted.workflow.worktree.is_none()
            && admitted.workflow.current_step_id.is_none(),
        "admitting must not pair a new execution with a dead run's launch data"
    );
}
