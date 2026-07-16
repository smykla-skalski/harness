use serde_json::json;

use super::*;
use crate::task_board::{ExternalProvider, ExternalSyncAction};

#[test]
fn review_summary_counts_only_applied_operations() {
    let summary = ReviewsProjectionAuditSummary::new(
        true,
        &[
            operation(true, ExternalSyncAction::Pull),
            operation(false, ExternalSyncAction::Conflict),
        ],
        0,
    );

    assert_eq!(summary.observed_operation_count, 2);
    assert_eq!(summary.operation_count, 1);
    assert_eq!(summary.applied_operation_count, 1);
    assert_eq!(summary.conflict_count, 1);
}

#[test]
fn aggregate_payload_preserves_evidence_and_counts_only_applied_operations() {
    let mut payload = json!({ "trigger": "requested" });
    add_summary_counts(
        &mut payload,
        7,
        &[
            operation(true, ExternalSyncAction::Pull),
            operation(false, ExternalSyncAction::Conflict),
        ],
    );

    assert_eq!(payload["total_items"], 7);
    assert_eq!(payload["observed_operation_count"], 2);
    assert_eq!(payload["operation_count"], 1);
    assert_eq!(payload["applied_operation_count"], 1);
    assert_eq!(payload["conflict_count"], 1);
    assert_eq!(
        payload["operation_evidence"].as_array().map(Vec::len),
        Some(2)
    );
}

fn operation(applied: bool, action: ExternalSyncAction) -> ExternalSyncOperation {
    ExternalSyncOperation {
        provider: ExternalProvider::GitHub,
        action,
        board_item_id: Some("task-1".to_owned()),
        external_id: Some("external-1".to_owned()),
        url: Some("https://example.test/items/1".to_owned()),
        dry_run: false,
        applied,
        changed_fields: Vec::new(),
        unsupported_fields: Vec::new(),
    }
}
