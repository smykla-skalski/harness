use std::hash::{DefaultHasher, Hash, Hasher};

use serde_json::{Value, json};

use crate::task_board::external::{ExternalSyncBatch, ExternalSyncScopeOutcome};
use crate::task_board::{ExternalProvider, ExternalSyncAction, ExternalSyncOperation};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(super) enum ScopeOutcomeKind {
    Succeeded,
    Failed,
    BackingOff,
}

impl ScopeOutcomeKind {
    const fn payload_value(self) -> &'static str {
        match self {
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::BackingOff => "backing_off",
        }
    }

    pub(super) const fn is_issue(self) -> bool {
        matches!(self, Self::Failed | Self::BackingOff)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ScopeAuditEvidence {
    pub(super) provider: ExternalProvider,
    pub(super) scope_id: String,
    pub(super) outcome: ScopeOutcomeKind,
    pub(super) error_code: Option<String>,
    pub(super) error: Option<String>,
}

impl ScopeAuditEvidence {
    fn capture(outcome: &ExternalSyncScopeOutcome) -> Self {
        Self {
            provider: outcome.provider,
            scope_id: outcome.scope_id.clone(),
            outcome: outcome_kind(outcome),
            error_code: outcome.error_code.clone(),
            error: outcome.error.clone(),
        }
    }

    pub(super) fn issue_fingerprint(&self) -> u64 {
        let mut hasher = DefaultHasher::new();
        self.outcome.hash(&mut hasher);
        self.error_code.hash(&mut hasher);
        self.error.hash(&mut hasher);
        hasher.finish()
    }

    fn payload(&self) -> Value {
        let mut payload = json!({
            "provider": self.provider,
            "scope_id": self.scope_id,
            "outcome": self.outcome.payload_value(),
        });
        if let Some(error_code) = &self.error_code {
            payload["error_code"] = json!(error_code);
        }
        if let Some(error) = &self.error {
            payload["error"] = json!(error);
        }
        payload
    }
}

#[derive(Debug, Clone, Default)]
pub(in crate::daemon::service::task_board_db) struct SyncExecutionMetrics {
    operations: Vec<ExternalSyncOperation>,
    scope_outcomes: Vec<ScopeAuditEvidence>,
    attempted_scope_count: usize,
    result_scope_count: usize,
    succeeded_scope_count: usize,
    failed_scope_count: usize,
    backing_off_scope_count: usize,
}

impl SyncExecutionMetrics {
    pub(in crate::daemon::service::task_board_db) fn capture(&mut self, batch: &ExternalSyncBatch) {
        self.operations.clone_from(&batch.operations);
        self.scope_outcomes = batch
            .scope_outcomes
            .iter()
            .map(ScopeAuditEvidence::capture)
            .collect();
        self.attempted_scope_count = batch.attempted_scope_count();
        self.result_scope_count = batch.result_scope_count();
        self.succeeded_scope_count = batch.succeeded_scope_count();
        self.failed_scope_count = batch.failed_scope_count();
        self.backing_off_scope_count = batch.backing_off_scope_count();
    }

    pub(super) fn has_applied_change(&self) -> bool {
        self.operations.iter().any(|operation| operation.applied)
    }

    pub(super) const fn failed_scope_count(&self) -> usize {
        self.failed_scope_count
    }

    pub(super) const fn backing_off_scope_count(&self) -> usize {
        self.backing_off_scope_count
    }

    pub(super) const fn all_scopes_backing_off(&self) -> bool {
        self.result_scope_count > 0
            && self.backing_off_scope_count == self.result_scope_count
            && self.failed_scope_count == 0
            && self.succeeded_scope_count == 0
    }

    pub(super) fn scope_outcomes(&self) -> &[ScopeAuditEvidence] {
        &self.scope_outcomes
    }
}

pub(super) fn add_summary_counts(
    payload: &mut Value,
    total_items: usize,
    operations: &[ExternalSyncOperation],
) {
    payload["total_items"] = json!(total_items);
    add_operation_metrics(payload, operations);
}

pub(super) fn add_execution_metrics(payload: &mut Value, metrics: &SyncExecutionMetrics) {
    payload["attempted_scope_count"] = json!(metrics.attempted_scope_count);
    payload["result_scope_count"] = json!(metrics.result_scope_count);
    payload["succeeded_scope_count"] = json!(metrics.succeeded_scope_count);
    payload["failed_scope_count"] = json!(metrics.failed_scope_count);
    payload["backing_off_scope_count"] = json!(metrics.backing_off_scope_count);
    add_operation_metrics(payload, &metrics.operations);
    payload["scope_outcomes"] = Value::Array(
        metrics
            .scope_outcomes
            .iter()
            .map(ScopeAuditEvidence::payload)
            .collect(),
    );
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

fn add_operation_metrics(payload: &mut Value, operations: &[ExternalSyncOperation]) {
    let applied_count = applied_operation_count(operations);
    payload["operation_count"] = json!(applied_count);
    payload["observed_operation_count"] = json!(operations.len());
    payload["applied_operation_count"] = json!(applied_count);
    payload["conflict_count"] = json!(conflict_count(operations));
    if !operations.is_empty() {
        payload["operation_evidence"] = json!(operations);
    }
}

fn outcome_kind(outcome: &ExternalSyncScopeOutcome) -> ScopeOutcomeKind {
    if outcome.error_code.is_some() || outcome.error.is_some() {
        return ScopeOutcomeKind::Failed;
    }
    let backing_off = ExternalSyncScopeOutcome::backing_off(outcome.provider, String::new());
    if outcome.kind == backing_off.kind {
        ScopeOutcomeKind::BackingOff
    } else {
        ScopeOutcomeKind::Succeeded
    }
}
