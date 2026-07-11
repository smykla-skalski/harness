use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, ReservedTaskBoardDispatch};
use crate::task_board::dispatch::build_dispatch_plan_with_policy_root;
use crate::task_board::{TaskBoardItem, TaskBoardStatus};

#[tokio::test]
async fn task_board_dispatch_intents_survive_until_worker_outcome() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    for item_id in ["task-dispatch-ok", "task-dispatch-failed"] {
        db.create_task_board_item(TaskBoardItem::new(
            item_id.to_owned(),
            "Dispatch".to_owned(),
            "Body".to_owned(),
            "2026-07-11T10:00:00Z".to_owned(),
        ))
        .await
        .expect("create item");
    }
    let item = db
        .task_board_item("task-dispatch-ok")
        .await
        .expect("load item");
    let lifecycle = build_dispatch_plan_with_policy_root(&item, dir.path()).applied_lifecycle();
    let applied = db
        .link_and_enqueue_task_board_dispatch("task-dispatch-ok", "session-1", "work-1", &lifecycle)
        .await
        .expect("enqueue dispatch");
    assert_eq!(applied.item.status, TaskBoardStatus::InProgress);
    let claim = db
        .claim_task_board_dispatch("task-dispatch-ok")
        .await
        .expect("claim dispatch")
        .expect("pending dispatch");
    assert!(
        db.claim_task_board_dispatch("task-dispatch-ok")
            .await
            .expect("second claim")
            .is_none()
    );
    sqlx::query(
        "UPDATE task_board_dispatch_intents SET claimed_at = '1970-01-01T00:00:00Z'
         WHERE intent_id = ?1",
    )
    .bind(&claim.intent_id)
    .execute(db.pool())
    .await
    .expect("expire claim");
    let reclaimed = db
        .claim_next_task_board_dispatch()
        .await
        .expect("reclaim dispatch")
        .expect("expired dispatch");
    assert_ne!(reclaimed.claim_token, claim.claim_token);
    db.complete_task_board_dispatch(&reclaimed.intent_id, &reclaimed.claim_token)
        .await
        .expect("complete dispatch");

    let failed = db
        .task_board_item("task-dispatch-failed")
        .await
        .expect("load failed item");
    let failed_lifecycle =
        build_dispatch_plan_with_policy_root(&failed, dir.path()).applied_lifecycle();
    db.link_and_enqueue_task_board_dispatch(
        "task-dispatch-failed",
        "session-2",
        "work-2",
        &failed_lifecycle,
    )
    .await
    .expect("enqueue failed dispatch");
    let failed_claim = db
        .claim_task_board_dispatch("task-dispatch-failed")
        .await
        .expect("claim failed dispatch")
        .expect("pending failed dispatch");
    db.fail_task_board_dispatch(
        &failed_claim.intent_id,
        &failed_claim.claim_token,
        "worker failed",
    )
    .await
    .expect("fail dispatch");
    let restored = db
        .task_board_item("task-dispatch-failed")
        .await
        .expect("restored item");
    assert_eq!(restored.status, TaskBoardStatus::Todo);
    assert!(restored.session_id.is_none());
    assert!(restored.work_item_id.is_none());
    assert_eq!(
        restored.workflow.last_error.as_deref(),
        Some("worker failed")
    );
}

#[tokio::test]
async fn task_board_dispatch_reservation_precedes_links_and_is_reclaimable() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    db.create_task_board_item(TaskBoardItem::new(
        "task-dispatch-reserved".to_owned(),
        "Reserved dispatch".to_owned(),
        "Body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    ))
    .await
    .expect("create item");
    let item = db
        .task_board_item("task-dispatch-reserved")
        .await
        .expect("load item");
    let plan = build_dispatch_plan_with_policy_root(&item, dir.path());
    let first = db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"))
        .await
        .expect("reserve dispatch");
    let (intent_id, preparation) = match first {
        ReservedTaskBoardDispatch::Preparing {
            intent_id,
            preparation,
        } => (intent_id, preparation),
        ReservedTaskBoardDispatch::Applied(_) => panic!("new reservation was already applied"),
    };
    assert_eq!(preparation.board_item_id, "task-dispatch-reserved");
    let still_todo = db
        .task_board_item("task-dispatch-reserved")
        .await
        .expect("load reserved item");
    assert_eq!(still_todo.status, TaskBoardStatus::Todo);
    assert!(still_todo.session_id.is_none());
    assert!(still_todo.work_item_id.is_none());

    let repeated = db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"))
        .await
        .expect("repeat reservation");
    assert!(matches!(
        repeated,
        ReservedTaskBoardDispatch::Preparing {
            intent_id: ref repeated_id,
            ..
        } if repeated_id == &intent_id
    ));

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
    let applied = db
        .complete_task_board_dispatch_preparation(&reclaimed)
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
