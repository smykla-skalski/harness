use sqlx::query_scalar;
use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::{
    BUILTIN_V1_EVALUATOR_IDENTITY, ExternalRef, ExternalRefProvider, ProviderExclusionAuditContext,
    ProviderExclusionRestoreOutcome, TaskBoardItem, TaskBoardLaneOrigin, TaskBoardStatus,
    TaskBoardTombstoneCause,
};

#[path = "provider_exclusion_restore_tests.rs"]
mod restore_tests;

#[path = "provider_exclusion_eligibility_tests.rs"]
mod eligibility_tests;

async fn connect() -> (tempfile::TempDir, AsyncDaemonDb) {
    let directory = tempdir().expect("tempdir");
    let path = directory.path().join("harness.db");
    let db = AsyncDaemonDb::connect(&path).await.expect("connect db");
    (directory, db)
}

fn pre_dispatch_item(id: &str) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        id.into(),
        "Title".into(),
        String::new(),
        "2026-07-23T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    item.tags = vec!["duplicate".into()];
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "42".into(),
        url: None,
        sync_state: None,
    }];
    item
}

fn exclusion_context(stored_external_ref: &str) -> ProviderExclusionAuditContext {
    ProviderExclusionAuditContext {
        provider: ExternalRefProvider::GitHub,
        incoming_external_ref: stored_external_ref.into(),
        stored_external_ref: stored_external_ref.into(),
        matched_label: "duplicate".into(),
    }
}

fn clean_restore_patch() -> TaskBoardItemPatch {
    TaskBoardItemPatch {
        tags: Some(Vec::new()),
        ..TaskBoardItemPatch::default()
    }
}

fn restored_item(outcome: ProviderExclusionRestoreOutcome) -> TaskBoardItem {
    match outcome {
        ProviderExclusionRestoreOutcome::Restored(item) => *item,
        other => panic!("expected a Restored outcome, got {other:?}"),
    }
}

async fn seed_dispatch_intent(db: &AsyncDaemonDb, item_id: &str, status: &str) {
    let claim_token = matches!(status, "preparing_claimed" | "starting").then_some("claim");
    let claimed_at =
        matches!(status, "preparing_claimed" | "starting").then_some("2026-07-23T00:00:00Z");
    sqlx::query(
        "INSERT INTO task_board_dispatch_intents (
             intent_id, item_id, session_id, work_item_id, workflow_execution_id,
             payload_json, status, attempts, available_at, claim_token, claimed_at,
             created_at, updated_at
         ) VALUES (?1, ?2, 'session-1', 'work-1', 'workflow-1', '{}',
                    ?3, 0, '2026-07-23T00:00:00Z', ?4, ?5,
                    '2026-07-23T00:00:00Z', '2026-07-23T00:00:00Z')",
    )
    .bind(format!("intent-{item_id}-{status}"))
    .bind(item_id)
    .bind(status)
    .bind(claim_token)
    .bind(claimed_at)
    .execute(db.pool())
    .await
    .expect("seed dispatch intent");
}

#[tokio::test]
async fn hides_a_pre_dispatch_item_and_records_exactly_one_audit_event() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");

    let mutation = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");

    assert!(mutation.item.is_deleted());
    assert_eq!(
        mutation.item.tombstone_cause,
        Some(TaskBoardTombstoneCause::ProviderExclusion)
    );

    let audit_count: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events
         WHERE kind = 'task_board.item.provider_exclusion_hidden' AND subject = 'item-1'",
    )
    .fetch_one(db.pool())
    .await
    .expect("count audit events");
    assert_eq!(
        audit_count, 1,
        "hide must record exactly one typed audit event even without a lane anchor"
    );
}

#[tokio::test]
async fn refuses_to_hide_an_item_with_any_admission_reservation() {
    for status in [
        "preparing",
        "preparing_claimed",
        "held",
        "pending",
        "workflow_prepared",
        "starting",
    ] {
        let (_directory, db) = connect().await;
        let created = db
            .create_task_board_item(pre_dispatch_item("item-1"))
            .await
            .expect("seed item");
        seed_dispatch_intent(&db, "item-1", status).await;

        let mutation = db
            .hide_task_board_item_for_provider_exclusion(
                "item-1",
                created.item_revision,
                TaskBoardItemPatch::default(),
                &exclusion_context("42"),
                None,
            )
            .await
            .expect("hide call succeeds");

        assert!(
            mutation.is_none(),
            "an item with a '{status}' dispatch intent must never be silently hidden"
        );
    }
}

#[tokio::test]
async fn refuses_to_hide_an_item_with_a_stale_revision() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");

    let mutation = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision + 1,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds");

    assert!(
        mutation.is_none(),
        "a stale expected_revision must never hide the row underneath a concurrent writer"
    );
}

#[tokio::test]
async fn refuses_to_hide_an_item_whose_provider_link_moved() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");

    let mutation = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("99"),
            None,
        )
        .await
        .expect("hide call succeeds");

    assert!(
        mutation.is_none(),
        "a context whose stored_external_ref no longer matches the row must never hide it"
    );
}

#[tokio::test]
async fn refuses_to_hide_an_item_past_pre_dispatch_status() {
    let (_directory, db) = connect().await;
    let mut item = pre_dispatch_item("item-1");
    item.status = TaskBoardStatus::InProgress;
    let created = db.create_task_board_item(item).await.expect("seed item");

    let mutation = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds");

    assert!(
        mutation.is_none(),
        "an item past pre-dispatch (Backlog/Todo) must never be silently hidden"
    );
}

#[tokio::test]
async fn refuses_to_hide_when_the_patch_does_not_carry_the_matched_label() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");

    // The patch never mentions tags at all, so the stored row keeps
    // whatever it already had ("duplicate", set by pre_dispatch_item) --
    // matching this context's claimed label. Claim a *different* label the
    // patched row will never carry, to prove hide fails closed instead of
    // tombstoning on unverified evidence.
    let context = ProviderExclusionAuditContext {
        provider: ExternalRefProvider::GitHub,
        incoming_external_ref: "42".into(),
        stored_external_ref: "42".into(),
        matched_label: "wontfix".into(),
    };

    let error = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision,
            TaskBoardItemPatch::default(),
            &context,
            None,
        )
        .await
        .expect_err("a patch that doesn't carry the claimed label must fail closed");

    assert_eq!(error.code(), "WORKFLOW_IO");
    let current = db.task_board_item("item-1").await.expect("current item");
    assert!(
        !current.is_deleted(),
        "the failed hide must not tombstone the item"
    );
}

#[tokio::test]
async fn hiding_a_parent_clears_and_reports_its_children_parent_link() {
    let (_directory, db) = connect().await;
    let created_parent = db
        .create_task_board_item(pre_dispatch_item("parent"))
        .await
        .expect("seed parent");
    let mut child = pre_dispatch_item("child");
    child.parent_item_id = Some("parent".into());
    let created_child = db.create_task_board_item(child).await.expect("seed child");

    db.hide_task_board_item_for_provider_exclusion(
        "parent",
        created_parent.item_revision,
        TaskBoardItemPatch::default(),
        &exclusion_context("42"),
        None,
    )
    .await
    .expect("hide call succeeds")
    .expect("eligible item is hidden");

    let child_snapshot = db
        .task_board_item_snapshot("child")
        .await
        .expect("load child snapshot");
    assert_eq!(
        child_snapshot.item.parent_item_id, None,
        "a hidden parent must not leave a live child pointing at it"
    );
    assert_eq!(
        child_snapshot.item_revision,
        created_child.item_revision + 1,
        "unparenting a child is itself a revisioned write"
    );

    let payload: String = query_scalar(
        "SELECT payload_json FROM audit_events
         WHERE kind = 'task_board.item.provider_exclusion_hidden' AND subject = 'parent'",
    )
    .fetch_one(db.pool())
    .await
    .expect("hide audit payload");
    let payload: serde_json::Value = serde_json::from_str(&payload).expect("parse payload");
    let unparented = payload["unparented_children"]
        .as_array()
        .expect("unparented_children array");
    assert_eq!(unparented.len(), 1);
    assert_eq!(unparented[0]["item_id"], "child");
    assert_eq!(unparented[0]["item_revision"], child_snapshot.item_revision);
}

#[tokio::test]
async fn hide_preserves_a_manual_lane_anchor_but_clears_an_automatic_one() {
    let (_directory, db) = connect().await;

    let mut manual = pre_dispatch_item("item-1");
    manual.lane_position = Some(0);
    manual.lane_origin = Some(TaskBoardLaneOrigin::Manual {
        actor: "person".into(),
    });
    manual.lane_set_at = Some("2026-07-23T00:00:00Z".into());
    let created_manual = db
        .create_task_board_item(manual)
        .await
        .expect("seed manual item");

    let mut automatic = pre_dispatch_item("item-2");
    automatic.lane_position = Some(1);
    automatic.lane_origin = Some(TaskBoardLaneOrigin::Automatic {
        producer: BUILTIN_V1_EVALUATOR_IDENTITY.into(),
    });
    automatic.lane_set_at = Some("2026-07-23T00:00:00Z".into());
    db.create_task_board_item(automatic)
        .await
        .expect("seed automatic item");

    let hidden_manual = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created_manual.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");
    let automatic_revision = db
        .task_board_item_snapshot("item-2")
        .await
        .expect("load shifted automatic item")
        .item_revision;
    let hidden_automatic = db
        .hide_task_board_item_for_provider_exclusion(
            "item-2",
            automatic_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");

    assert_eq!(
        hidden_manual.item.lane_position,
        Some(0),
        "a manual anchor must survive the tombstone"
    );
    assert_eq!(
        hidden_manual.item.lane_origin,
        Some(TaskBoardLaneOrigin::Manual {
            actor: "person".into()
        })
    );
    assert_eq!(
        hidden_manual.item.lane_set_at,
        Some("2026-07-23T00:00:00Z".into())
    );

    assert_eq!(
        hidden_automatic.item.lane_position, None,
        "automatic placement must not survive the tombstone"
    );
    assert_eq!(hidden_automatic.item.lane_origin, None);
    assert_eq!(hidden_automatic.item.lane_set_at, None);

    // Another manual card claims the same slot while item-1 is hidden, so
    // restoring it must reinsert collision-safely instead of colliding.
    let mut occupant = pre_dispatch_item("occupant");
    occupant.lane_position = Some(0);
    occupant.lane_origin = Some(TaskBoardLaneOrigin::Manual {
        actor: "someone-else".into(),
    });
    occupant.lane_set_at = Some("2026-07-23T00:30:00Z".into());
    let created_occupant = db
        .create_task_board_item(occupant)
        .await
        .expect("seed occupant");

    let restored_manual = restored_item(
        db.restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden_manual.item_revision,
            clean_restore_patch(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("restore call succeeds"),
    );

    assert_eq!(
        restored_manual.lane_origin,
        Some(TaskBoardLaneOrigin::Manual {
            actor: "person".into()
        }),
        "the manual anchor must survive a full hide-then-restore round trip"
    );
    assert_eq!(restored_manual.lane_position, Some(0));

    let occupant_snapshot = db
        .task_board_item_snapshot("occupant")
        .await
        .expect("load occupant snapshot");
    assert_eq!(
        occupant_snapshot.item_revision,
        created_occupant.item_revision + 1,
        "reinserting the restored manual anchor must shift the colliding occupant, not collide with it"
    );

    let restored_automatic = restored_item(
        db.restore_task_board_item_for_provider_exclusion(
            "item-2",
            hidden_automatic.item_revision,
            TaskBoardItemPatch {
                tags: Some(vec!["kind/bug".into()]),
                ..TaskBoardItemPatch::default()
            },
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("automatic restore succeeds"),
    );
    assert_eq!(restored_automatic.status, TaskBoardStatus::Todo);
    assert_eq!(restored_automatic.lane_position, Some(0));
    assert_eq!(
        restored_automatic.lane_origin,
        Some(TaskBoardLaneOrigin::Automatic {
            producer: BUILTIN_V1_EVALUATOR_IDENTITY.into()
        }),
        "automatic placement must be recomputed from current evidence after restore"
    );
}
