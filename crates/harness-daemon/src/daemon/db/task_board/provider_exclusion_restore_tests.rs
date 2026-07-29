use sqlx::query_scalar;

use super::{clean_restore_patch, connect, exclusion_context, pre_dispatch_item, restored_item};
use crate::task_board::store::TaskBoardItemPatch;
use crate::task_board::types::{ExternalRef, ExternalRefProvider, ExternalRefSyncState};
use crate::task_board::{
    ProviderExclusionAuditContext, ProviderExclusionRestoreOutcome, TaskBoardLaneOrigin,
    matched_exclusion_label,
};

#[path = "provider_exclusion_restore_parent_tests.rs"]
mod parent_tests;

#[path = "provider_exclusion_restore_conflict_tests.rs"]
mod conflict_tests;

#[path = "provider_exclusion_restore_override_tests.rs"]
mod override_tests;

#[tokio::test]
async fn restores_a_tombstoned_item_reconciling_fields_and_records_one_audit_event() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");
    let hidden = db
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

    let patch = TaskBoardItemPatch {
        title: Some("Un-excluded title".into()),
        tags: Some(vec!["kind/bug".into()]),
        ..TaskBoardItemPatch::default()
    };
    let restored = restored_item(
        db.restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            patch,
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("restore call succeeds"),
    );

    assert!(!restored.is_deleted());
    assert_eq!(restored.tombstone_cause, None);
    assert_eq!(restored.title, "Un-excluded title");
    assert_eq!(restored.tags, vec!["kind/bug".to_string()]);

    let restored_count: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events
         WHERE kind = 'task_board.item.provider_exclusion_restored' AND subject = 'item-1'",
    )
    .fetch_one(db.pool())
    .await
    .expect("count restore audit events");
    assert_eq!(
        restored_count, 1,
        "restore must record exactly one typed audit event"
    );

    let decided_count: i64 = query_scalar(
        "SELECT COUNT(*) FROM audit_events
         WHERE kind = 'task_board.item.triage_decided' AND subject = 'item-1'",
    )
    .fetch_one(db.pool())
    .await
    .expect("count triage-decided audit events");
    assert_eq!(
        decided_count, 0,
        "a restore's own triage evaluation must never also emit a separate triage_decided event"
    );

    let payload: String = query_scalar(
        "SELECT payload_json FROM audit_events
         WHERE kind = 'task_board.item.provider_exclusion_restored' AND subject = 'item-1'",
    )
    .fetch_one(db.pool())
    .await
    .expect("restore audit payload");
    let payload: serde_json::Value = serde_json::from_str(&payload).expect("parse payload");
    assert!(
        payload["outcome_kind"].is_string(),
        "restore audit must record which triage outcome kind occurred"
    );
    let decision = &payload["decision"];
    assert!(decision["verdict"].is_string());
    assert!(decision["reason_code"].is_string());
    assert!(decision["cause"].is_string());
    assert!(decision["evaluator_identity"].is_string());
    assert!(decision["evaluator_version"].is_number());
    assert!(decision["decided_at"].is_string());
    assert!(
        decision.get("reason_detail").is_none(),
        "restore audit must omit reason_detail"
    );
    assert!(
        decision.get("evidence_fingerprint").is_none(),
        "restore audit must omit evidence_fingerprint"
    );
    assert!(
        !payload["sync_conflicts"]["policy_evaluated"]
            .as_bool()
            .expect("policy_evaluated bool"),
        "a restore outside Both+Report must record conflict policy as not evaluated"
    );
}

#[tokio::test]
async fn hide_applies_the_incoming_patch_and_restore_recovers_the_matched_label() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");

    // The patch mirrors what the sync layer's reconciliation_patch computes
    // for the incoming excluded task: the label that triggered the
    // exclusion, and a refreshed sync_state baseline.
    let hide_patch = TaskBoardItemPatch {
        title: Some("Closed as wontfix".into()),
        tags: Some(vec!["wontfix".into()]),
        external_refs: Some(vec![ExternalRef {
            provider: ExternalRefProvider::GitHub,
            external_id: "42".into(),
            url: None,
            sync_state: Some(ExternalRefSyncState {
                title: Some("Closed as wontfix".into()),
                labels: vec!["wontfix".into()],
                ..ExternalRefSyncState::default()
            }),
        }]),
        ..TaskBoardItemPatch::default()
    };
    let hide_context = ProviderExclusionAuditContext {
        provider: ExternalRefProvider::GitHub,
        incoming_external_ref: "42".into(),
        stored_external_ref: "42".into(),
        matched_label: "wontfix".into(),
    };
    let hidden = db
        .hide_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision,
            hide_patch,
            &hide_context,
            None,
        )
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");

    assert_eq!(hidden.item.title, "Closed as wontfix");
    assert_eq!(hidden.item.tags, vec!["wontfix".to_string()]);
    assert_eq!(
        hidden.item.external_refs[0]
            .sync_state
            .as_ref()
            .expect("sync state refreshed")
            .labels,
        vec!["wontfix".to_string()],
        "hide must refresh the ref's sync_state baseline instead of keeping the pre-exclusion one"
    );

    // The prior label is recovered from the tombstoned row's own tags, not
    // a fresh guess, matching what a real restore caller would do.
    let matched_label =
        matched_exclusion_label(&hidden.item.tags).expect("tombstone carries the label");
    assert_eq!(matched_label, "wontfix");

    let restore_patch = TaskBoardItemPatch {
        tags: Some(vec!["kind/bug".into()]),
        ..TaskBoardItemPatch::default()
    };
    let restore_context = ProviderExclusionAuditContext {
        provider: ExternalRefProvider::GitHub,
        incoming_external_ref: "42".into(),
        stored_external_ref: "42".into(),
        matched_label,
    };
    let restored = restored_item(
        db.restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            restore_patch,
            &restore_context,
            None,
        )
        .await
        .expect("restore call succeeds"),
    );

    assert_eq!(restored.tags, vec!["kind/bug".to_string()]);

    let payload: String = query_scalar(
        "SELECT payload_json FROM audit_events
         WHERE kind = 'task_board.item.provider_exclusion_restored' AND subject = 'item-1'",
    )
    .fetch_one(db.pool())
    .await
    .expect("restore audit payload");
    let payload: serde_json::Value = serde_json::from_str(&payload).expect("parse payload");
    assert_eq!(
        payload["provider_exclusion"]["matched_label"], "wontfix",
        "restore audit must report the label recovered from the tombstoned row"
    );
}

#[tokio::test]
async fn refuses_to_restore_an_item_with_a_stale_revision() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");
    let hidden = db
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

    let outcome = db
        .restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision + 1,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("restore call succeeds");

    assert!(
        matches!(outcome, ProviderExclusionRestoreOutcome::NotApplied),
        "a stale expected_revision must never restore the row underneath a concurrent writer"
    );
}

#[tokio::test]
async fn refuses_to_restore_while_the_patch_keeps_an_exclusion_label() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");
    let hidden = db
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

    let error = db
        .restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect_err("an exclusion label must keep the tombstone hidden");

    assert_eq!(error.code(), "WORKFLOW_IO");
    let current = db
        .task_board_item_snapshot("item-1")
        .await
        .expect("load current item");
    assert!(current.item.is_deleted());
    assert_eq!(
        current.item_revision, hidden.item_revision,
        "the failed restore must roll back every row mutation"
    );
}

#[tokio::test]
async fn refuses_to_restore_an_item_whose_provider_link_moved() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");
    let hidden = db
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

    let outcome = db
        .restore_task_board_item_for_provider_exclusion(
            "item-1",
            hidden.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("99"),
            None,
        )
        .await
        .expect("restore call succeeds");

    assert!(
        matches!(outcome, ProviderExclusionRestoreOutcome::NotApplied),
        "a context whose stored_external_ref no longer matches the row must never restore it"
    );
}

#[tokio::test]
async fn refuses_to_restore_an_item_that_is_not_provider_exclusion_tombstoned() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("item-1"))
        .await
        .expect("seed item");

    let outcome = db
        .restore_task_board_item_for_provider_exclusion(
            "item-1",
            created.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("restore call succeeds");

    assert!(
        matches!(outcome, ProviderExclusionRestoreOutcome::NotApplied),
        "a live, never-hidden item must never be treated as a provider-exclusion tombstone"
    );
}

#[tokio::test]
async fn restores_a_legacy_manually_assigned_item_id_unchanged() {
    let (_directory, db) = connect().await;
    let created = db
        .create_task_board_item(pre_dispatch_item("legacy-imported-issue-7"))
        .await
        .expect("seed item");
    let hidden = db
        .hide_task_board_item_for_provider_exclusion(
            "legacy-imported-issue-7",
            created.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide call succeeds")
        .expect("eligible item is hidden");

    let restored = restored_item(
        db.restore_task_board_item_for_provider_exclusion(
            "legacy-imported-issue-7",
            hidden.item_revision,
            clean_restore_patch(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("restore call succeeds"),
    );

    assert_eq!(
        restored.id, "legacy-imported-issue-7",
        "restore must never regenerate a deterministic id in place of the actual stored one"
    );
}

#[tokio::test]
async fn restore_clamps_a_preserved_manual_anchor_after_the_lane_shrinks() {
    let (_directory, db) = connect().await;
    let first = db
        .create_task_board_item(pre_dispatch_item("first"))
        .await
        .expect("seed first");
    let second = db
        .create_task_board_item(pre_dispatch_item("second"))
        .await
        .expect("seed second");
    let mut anchored = pre_dispatch_item("anchored");
    anchored.lane_position = Some(2);
    anchored.lane_origin = Some(TaskBoardLaneOrigin::Manual {
        actor: "person".into(),
    });
    anchored.lane_set_at = Some("2026-07-23T00:30:00Z".into());
    let anchored = db
        .create_task_board_item(anchored)
        .await
        .expect("seed anchored");

    let hidden_anchor = db
        .hide_task_board_item_for_provider_exclusion(
            "anchored",
            anchored.item_revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide anchor")
        .expect("anchor is hidden");
    for (id, revision) in [
        ("first", first.item_revision),
        ("second", second.item_revision),
    ] {
        db.hide_task_board_item_for_provider_exclusion(
            id,
            revision,
            TaskBoardItemPatch::default(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("hide lane member")
        .expect("lane member is hidden");
    }

    let restored = restored_item(
        db.restore_task_board_item_for_provider_exclusion(
            "anchored",
            hidden_anchor.item_revision,
            clean_restore_patch(),
            &exclusion_context("42"),
            None,
        )
        .await
        .expect("restore anchor"),
    );

    assert_eq!(restored.lane_position, Some(0));
    assert_eq!(
        restored.lane_origin,
        Some(TaskBoardLaneOrigin::Manual {
            actor: "person".into()
        })
    );
}
