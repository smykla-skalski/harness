use serde_json::{Value, json};

use crate::task_board::{ExternalSyncAction, ExternalSyncOperation};

use super::SyncExecutionMetrics;

pub(super) fn add_summary_counts(
    payload: &mut Value,
    total_items: usize,
    operations: &[ExternalSyncOperation],
) {
    payload["total_items"] = json!(total_items);
    add_operation_counts(payload, operations);
}

fn add_operation_counts(payload: &mut Value, operations: &[ExternalSyncOperation]) {
    payload["operation_count"] = json!(operations.len());
    payload["applied_operation_count"] = json!(applied_operation_count(operations));
    payload["conflict_count"] = json!(conflict_count(operations));
}

pub(super) fn add_execution_metrics(payload: &mut Value, metrics: &SyncExecutionMetrics) {
    payload["attempted_scope_count"] = json!(metrics.attempted_scope_count);
    payload["result_scope_count"] = json!(metrics.result_scope_count);
    payload["succeeded_scope_count"] = json!(metrics.succeeded_scope_count);
    payload["failed_scope_count"] = json!(metrics.failed_scope_count);
    payload["backing_off_scope_count"] = json!(metrics.backing_off_scope_count);
    payload["operation_count"] = json!(metrics.operation_count);
    payload["applied_operation_count"] = json!(metrics.applied_operation_count);
    payload["conflict_count"] = json!(metrics.conflict_count);
}

pub(super) fn applied_operation_count(operations: &[ExternalSyncOperation]) -> usize {
    operations
        .iter()
        .filter(|operation| operation.applied)
        .count()
}

pub(super) fn conflict_count(operations: &[ExternalSyncOperation]) -> usize {
    operations
        .iter()
        .filter(|operation| operation.action == ExternalSyncAction::Conflict)
        .count()
}
