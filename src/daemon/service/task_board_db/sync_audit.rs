use serde_json::{Value, json};

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{TaskBoardSyncRequest, TaskBoardSyncResponse};
use crate::errors::CliError;
use crate::task_board::{
    ExternalProvider, ExternalSyncConflictPolicy, ExternalSyncDirection, ExternalSyncOperation,
};

use metrics::{add_execution_metrics, add_summary_counts, applied_operation_count, conflict_count};
use persistence::persist_sync_audit_result;
use state::{AuditObservation, PendingAudit, plan_audit};

#[path = "sync_audit_metrics.rs"]
mod metrics;
#[path = "sync_audit_persistence.rs"]
mod persistence;
#[path = "sync_audit_state.rs"]
mod state;

pub(super) use metrics::SyncExecutionMetrics;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum TaskBoardSyncAuditTrigger {
    Requested,
    Orchestrator,
    ReviewsProjection,
    ReviewsTargetedRefresh,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ReviewsProjectionAuditSummary {
    stable: bool,
    observed_operation_count: usize,
    operation_count: usize,
    applied_operation_count: usize,
    conflict_count: usize,
    snapshot_update_count: usize,
}

impl ReviewsProjectionAuditSummary {
    pub(crate) fn new(
        stable: bool,
        operations: &[ExternalSyncOperation],
        snapshot_update_count: usize,
    ) -> Self {
        let applied_operation_count = applied_operation_count(operations);
        Self {
            stable,
            observed_operation_count: operations.len(),
            operation_count: applied_operation_count,
            applied_operation_count,
            conflict_count: conflict_count(operations),
            snapshot_update_count,
        }
    }

    pub(crate) const fn is_stable(&self) -> bool {
        self.stable
    }

    const fn has_applied_change(&self) -> bool {
        self.applied_operation_count > 0 || self.snapshot_update_count > 0
    }
}

impl TaskBoardSyncAuditTrigger {
    const fn payload_value(self) -> &'static str {
        match self {
            Self::Requested => "requested",
            Self::Orchestrator => "orchestrator",
            Self::ReviewsProjection => "reviews_projection",
            Self::ReviewsTargetedRefresh => "reviews_targeted_refresh",
        }
    }

    const fn actor(self) -> &'static str {
        match self {
            Self::Requested => "Harness daemon",
            Self::Orchestrator => "Task Board orchestrator",
            Self::ReviewsProjection => "Reviews sync",
            Self::ReviewsTargetedRefresh => "Reviews refresh",
        }
    }
}

pub(super) async fn record_request_result(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
    trigger: TaskBoardSyncAuditTrigger,
    result: &Result<TaskBoardSyncResponse, CliError>,
    metrics: &SyncExecutionMetrics,
) -> Result<(), CliError> {
    let observation = AuditObservation::for_request(result.as_ref().err(), metrics);
    let Some(pending) = plan_audit(db, trigger, observation) else {
        return Ok(());
    };
    let mut payload = request_payload(request, trigger);
    pending.add_recovery_to_payload(&mut payload);
    add_execution_metrics(&mut payload, metrics);
    if let Ok(summary) = result {
        add_summary_counts(&mut payload, summary.total, &summary.operations);
    }
    persist_sync_audit_result(db, trigger, payload, result).await?;
    pending.commit();
    Ok(())
}

pub(crate) async fn record_reviews_projection_result(
    db: &AsyncDaemonDb,
    result: &Result<ReviewsProjectionAuditSummary, CliError>,
) {
    record_reviews_result(db, TaskBoardSyncAuditTrigger::ReviewsProjection, result).await;
}

pub(crate) async fn record_targeted_reviews_projection_result(
    db: &AsyncDaemonDb,
    result: &Result<ReviewsProjectionAuditSummary, CliError>,
) {
    record_reviews_result(
        db,
        TaskBoardSyncAuditTrigger::ReviewsTargetedRefresh,
        result,
    )
    .await;
}

async fn record_reviews_result(
    db: &AsyncDaemonDb,
    trigger: TaskBoardSyncAuditTrigger,
    result: &Result<ReviewsProjectionAuditSummary, CliError>,
) {
    let Some(pending) = reviews_pending_audit(db, trigger, result) else {
        return;
    };
    let mut payload = reviews_payload(trigger);
    pending.add_recovery_to_payload(&mut payload);
    if let Ok(summary) = result {
        add_reviews_summary(&mut payload, summary);
    }
    persist_reviews_audit(db, trigger, pending, payload, result).await;
}

fn reviews_pending_audit(
    db: &AsyncDaemonDb,
    trigger: TaskBoardSyncAuditTrigger,
    result: &Result<ReviewsProjectionAuditSummary, CliError>,
) -> Option<PendingAudit> {
    let has_applied_change = result
        .as_ref()
        .is_ok_and(ReviewsProjectionAuditSummary::has_applied_change);
    match result {
        Ok(summary) if !summary.is_stable() => has_applied_change.then(PendingAudit::untracked),
        _ => plan_audit(
            db,
            trigger,
            AuditObservation::general(result.as_ref().err(), has_applied_change),
        ),
    }
}

async fn persist_reviews_audit(
    db: &AsyncDaemonDb,
    trigger: TaskBoardSyncAuditTrigger,
    pending: PendingAudit,
    payload: Value,
    result: &Result<ReviewsProjectionAuditSummary, CliError>,
) {
    if let Err(error) = persist_sync_audit_result(db, trigger, payload, result).await {
        log_reviews_audit_failure(trigger, &error);
        return;
    }
    pending.commit();
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_reviews_audit_failure(trigger: TaskBoardSyncAuditTrigger, error: &CliError) {
    tracing::error!(
        %error,
        trigger = trigger.payload_value(),
        "task-board sync audit persistence failed"
    );
}

fn request_payload(request: &TaskBoardSyncRequest, trigger: TaskBoardSyncAuditTrigger) -> Value {
    json!({
        "trigger": trigger.payload_value(),
        "status": request.status,
        "provider": request.provider,
        "direction": request.direction,
        "conflict_policy": request.conflict_policy,
        "dry_run": request.dry_run,
    })
}

fn reviews_payload(trigger: TaskBoardSyncAuditTrigger) -> Value {
    json!({
        "trigger": trigger.payload_value(),
        "provider": ExternalProvider::GitHub,
        "direction": ExternalSyncDirection::Pull,
        "conflict_policy": ExternalSyncConflictPolicy::Report,
        "dry_run": false,
    })
}

fn add_reviews_summary(payload: &mut Value, summary: &ReviewsProjectionAuditSummary) {
    payload["stable"] = json!(summary.stable);
    payload["observed_operation_count"] = json!(summary.observed_operation_count);
    payload["operation_count"] = json!(summary.operation_count);
    payload["applied_operation_count"] = json!(summary.applied_operation_count);
    payload["conflict_count"] = json!(summary.conflict_count);
    payload["snapshot_update_count"] = json!(summary.snapshot_update_count);
}

#[cfg(test)]
#[path = "sync_audit_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "sync_audit_acceptance_tests.rs"]
mod acceptance_tests;
