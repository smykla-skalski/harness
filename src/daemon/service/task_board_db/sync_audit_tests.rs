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

fn metrics_with_ambiguous(references: &[&str]) -> SyncExecutionMetrics {
    let mut metrics = SyncExecutionMetrics::default();
    metrics.capture(&crate::task_board::external::ExternalSyncBatch {
        operations: Vec::new(),
        external_create_follow_ups: Vec::new(),
        scope_outcomes: Vec::new(),
        ambiguous_references: references.iter().map(|value| (*value).to_owned()).collect(),
        first_provider_failure: None,
        terminal_error: None,
    });
    metrics
}

#[test]
fn a_skipped_reference_is_named_in_the_payload() {
    let mut payload = json!({ "trigger": "requested" });

    add_execution_metrics(
        &mut payload,
        &metrics_with_ambiguous(&["Owner/repo#689"]),
    );

    assert_eq!(payload["ambiguous_reference_count"], 1);
    assert_eq!(payload["ambiguous_references"][0], "Owner/repo#689");
}

/// A clean run keeps the payload it always had, so the key showing up at all
/// means something needs attention.
#[test]
fn a_run_that_skipped_nothing_carries_no_ambiguity_keys() {
    let mut payload = json!({ "trigger": "requested" });

    add_execution_metrics(&mut payload, &metrics_with_ambiguous(&[]));

    assert!(payload.get("ambiguous_references").is_none());
    assert!(payload.get("ambiguous_reference_count").is_none());
}
