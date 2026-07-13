use std::collections::HashMap;

use tempfile::tempdir;

use crate::daemon::db::{AsyncDaemonDb, NewApprovalGrant, ReservedTaskBoardDispatch};
use crate::task_board::{
    PolicyAction, PolicyReasonCode, SessionIntent, TaskBoardItem, TaskBoardStatus,
    build_dispatch_plans_with_policy,
};

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
    let lifecycle = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0)
    .applied_lifecycle();
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
    let failed_lifecycle = build_dispatch_plans_with_policy(
        &[failed],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0)
    .applied_lifecycle();
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
        .complete_task_board_dispatch_preparation(
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
async fn existing_session_without_work_item_is_reservable() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let mut item = TaskBoardItem::new(
        "task-existing-session".to_owned(),
        "Existing session dispatch".to_owned(),
        "Body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    );
    item.session_id = Some("session-existing".into());
    db.create_task_board_item(item).await.expect("create item");
    let item = db
        .task_board_item("task-existing-session")
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

    let reserved = db
        .reserve_task_board_dispatch(&plan, "control-plane", None, false)
        .await;

    assert!(
        reserved.is_ok(),
        "existing session without work item should reserve: {reserved:?}"
    );
}

#[tokio::test]
async fn existing_session_with_mismatched_session_id_is_rejected() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let mut item = TaskBoardItem::new(
        "task-existing-mismatch".to_owned(),
        "Existing session dispatch".to_owned(),
        "Body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    );
    item.session_id = Some("session-existing".into());
    db.create_task_board_item(item).await.expect("create item");
    let item = db
        .task_board_item("task-existing-mismatch")
        .await
        .expect("load item");
    let mut plan = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    plan.session = SessionIntent::Existing {
        session_id: "session-other".into(),
    };

    let reserved = db
        .reserve_task_board_dispatch(&plan, "control-plane", None, false)
        .await
        .expect_err("mismatched session id must be rejected");

    assert!(
        reserved
            .message()
            .contains("changed before dispatch reservation"),
        "unexpected error: {reserved:?}"
    );
}

#[tokio::test]
async fn existing_session_with_work_item_is_rejected() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let mut item = TaskBoardItem::new(
        "task-existing-linked".to_owned(),
        "Existing session dispatch".to_owned(),
        "Body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    );
    item.session_id = Some("session-existing".into());
    item.work_item_id = Some("work-existing".into());
    db.create_task_board_item(item).await.expect("create item");
    let item = db
        .task_board_item("task-existing-linked")
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

    let reserved = db
        .reserve_task_board_dispatch(&plan, "control-plane", None, false)
        .await
        .expect_err("existing work item must be rejected");

    assert!(
        reserved
            .message()
            .contains("changed before dispatch reservation"),
        "unexpected error: {reserved:?}"
    );
}

#[tokio::test]
async fn active_dispatch_intent_requires_matching_linkage() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    let item_id = "task-dispatch-linkage";
    db.create_task_board_item(TaskBoardItem::new(
        item_id.to_owned(),
        "Dispatch linkage".to_owned(),
        "Body".to_owned(),
        "2026-07-11T10:00:00Z".to_owned(),
    ))
    .await
    .expect("create item");
    let item = db.task_board_item(item_id).await.expect("load item");
    let lifecycle = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0)
    .applied_lifecycle();
    let original = db
        .link_and_enqueue_task_board_dispatch(item_id, "session-1", "work-1", &lifecycle)
        .await
        .expect("enqueue original dispatch");

    let session_error = db
        .link_and_enqueue_task_board_dispatch(item_id, "session-2", "work-1", &lifecycle)
        .await
        .expect_err("mismatched session must conflict");
    assert_eq!(session_error.code(), "KSRCLI092");
    let work_item_error = db
        .link_and_enqueue_task_board_dispatch(item_id, "session-1", "work-2", &lifecycle)
        .await
        .expect_err("mismatched work item must conflict");
    assert_eq!(work_item_error.code(), "KSRCLI092");
    let repeated = db
        .link_and_enqueue_task_board_dispatch(item_id, "session-1", "work-1", &lifecycle)
        .await
        .expect("matching retry");
    assert_eq!(repeated, original);

    let active_intents: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM task_board_dispatch_intents
         WHERE item_id = ?1 AND status IN ('pending', 'starting')",
    )
    .bind(item_id)
    .fetch_one(db.pool())
    .await
    .expect("count active intents");
    assert_eq!(active_intents, 1);
    let linked = db.task_board_item(item_id).await.expect("load linked item");
    assert_eq!(linked.session_id.as_deref(), Some("session-1"));
    assert_eq!(linked.work_item_id.as_deref(), Some("work-1"));
}

#[tokio::test]
async fn approved_grant_is_consumed_at_reservation() {
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open db");
    db.create_task_board_item(TaskBoardItem::new(
        "task-grant-consume".to_owned(),
        "Grant consume".to_owned(),
        "Body".to_owned(),
        "2026-07-14T10:00:00Z".to_owned(),
    ))
    .await
    .expect("create item");

    let pending = db
        .ensure_pending_approval_grant(&NewApprovalGrant {
            board_item_id: "task-grant-consume".to_owned(),
            action: PolicyAction::SpawnAgent,
            canvas_id: Some("canvas-1".to_owned()),
            canvas_revision: 1,
            node_id: "approve-spawn".to_owned(),
            reason_code: PolicyReasonCode::ApprovalRequired,
            expiry_seconds: None,
        })
        .await
        .expect("create pending grant");
    db.resolve_approval_grant(&pending.id, true, "operator")
        .await
        .expect("approve grant");

    let item = db
        .task_board_item("task-grant-consume")
        .await
        .expect("load item");
    let mut plan = build_dispatch_plans_with_policy(
        &[item],
        None,
        None,
        crate::task_board::SpawnGateSwitches::default(),
        &HashMap::new(),
    )
    .remove(0);
    plan.consumed_approval_grant_id = Some(pending.id.clone());

    let reserved = db
        .reserve_task_board_dispatch(&plan, "control-plane", Some("/tmp/project"), false)
        .await
        .expect("reserve dispatch");
    let intent_id = match reserved {
        ReservedTaskBoardDispatch::Preparing { intent_id, .. } => intent_id,
        ReservedTaskBoardDispatch::Applied(_) => panic!("new reservation was already applied"),
    };
    let claim = db
        .claim_task_board_dispatch_preparation(&intent_id)
        .await
        .expect("claim preparation")
        .expect("pending preparation");
    db.complete_task_board_dispatch_preparation(
        &claim,
        "harness/session-grant",
        "/tmp/session-grant",
    )
    .await
    .expect("complete preparation");

    assert!(
        db.live_approval_grant("task-grant-consume", PolicyAction::SpawnAgent, 1)
            .await
            .expect("live lookup")
            .is_none(),
        "reservation must consume the approved grant one-shot"
    );
}
