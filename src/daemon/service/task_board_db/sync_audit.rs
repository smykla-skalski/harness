use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::daemon::audit_events::{AuditEventDraft, record_audit_result_in_db};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{TaskBoardSyncRequest, TaskBoardSyncResponse};
use crate::errors::CliError;
use crate::task_board::{
    ExternalProvider, ExternalSyncConflictPolicy, ExternalSyncDirection, ExternalSyncOperation,
};

use super::SyncExecutionMetrics;
use metrics::{add_execution_metrics, add_summary_counts, applied_operation_count, conflict_count};

#[path = "sync_audit_metrics.rs"]
mod metrics;

const BACKGROUND_FAILURE_REPEAT_INTERVAL: Duration = Duration::from_mins(15);

static BACKGROUND_AUDIT_STATE: OnceLock<Mutex<BackgroundAuditState>> = OnceLock::new();

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
        Self {
            stable,
            operation_count: operations.len(),
            applied_operation_count: applied_operation_count(operations),
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AuditDecision {
    Suppress,
    Record { recovered: bool },
}

#[derive(Debug, Default)]
struct BackgroundAuditState {
    failures: HashMap<(u64, TaskBoardSyncAuditTrigger), HashMap<u64, Instant>>,
}

impl BackgroundAuditState {
    fn decide(
        &mut self,
        database_fingerprint: u64,
        trigger: TaskBoardSyncAuditTrigger,
        failure_fingerprint: Option<u64>,
        has_applied_change: bool,
        now: Instant,
    ) -> AuditDecision {
        if trigger == TaskBoardSyncAuditTrigger::Requested {
            return AuditDecision::Record { recovered: false };
        }
        let scope = (database_fingerprint, trigger);
        if let Some(fingerprint) = failure_fingerprint {
            return self.decide_failure(scope, fingerprint, now);
        }

        let recovered = self.failures.remove(&scope).is_some();
        if recovered || has_applied_change {
            AuditDecision::Record { recovered }
        } else {
            AuditDecision::Suppress
        }
    }

    fn decide_failure(
        &mut self,
        scope: (u64, TaskBoardSyncAuditTrigger),
        fingerprint: u64,
        now: Instant,
    ) -> AuditDecision {
        let trigger_failures = self.failures.entry(scope).or_default();
        trigger_failures.retain(|_, last_recorded_at| {
            now.saturating_duration_since(*last_recorded_at) < BACKGROUND_FAILURE_REPEAT_INTERVAL
        });
        let should_record = trigger_failures
            .get(&fingerprint)
            .is_none_or(|last_recorded_at| {
                now.saturating_duration_since(*last_recorded_at)
                    >= BACKGROUND_FAILURE_REPEAT_INTERVAL
            });
        if !should_record {
            return AuditDecision::Suppress;
        }

        trigger_failures.insert(fingerprint, now);
        AuditDecision::Record { recovered: false }
    }
}

pub(super) async fn record_request_result(
    db: &AsyncDaemonDb,
    request: &TaskBoardSyncRequest,
    trigger: TaskBoardSyncAuditTrigger,
    result: &Result<TaskBoardSyncResponse, CliError>,
    metrics: &SyncExecutionMetrics,
) {
    let operations = result
        .as_ref()
        .ok()
        .map(|summary| summary.operations.as_slice());
    let decision = audit_decision(
        db,
        trigger,
        result.as_ref().err(),
        metrics.attempted_scope_count > 0
            || operations
                .unwrap_or_default()
                .iter()
                .any(|operation| operation.applied),
    );
    let AuditDecision::Record { recovered } = decision else {
        return;
    };
    let mut payload = json!({
        "trigger": trigger.payload_value(),
        "status": request.status,
        "provider": request.provider,
        "direction": request.direction,
        "conflict_policy": request.conflict_policy,
        "dry_run": request.dry_run,
    });
    add_recovery(&mut payload, recovered);
    add_execution_metrics(&mut payload, metrics);
    if let Ok(summary) = result {
        add_summary_counts(&mut payload, summary.total, &summary.operations);
    }
    record(db, trigger, payload, result).await;
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
    let has_applied_change = result
        .as_ref()
        .is_ok_and(ReviewsProjectionAuditSummary::has_applied_change);
    let decision = match result {
        Ok(summary) if !summary.is_stable() => unstable_projection_decision(has_applied_change),
        _ => audit_decision(db, trigger, result.as_ref().err(), has_applied_change),
    };
    let AuditDecision::Record { recovered } = decision else {
        return;
    };
    let mut payload = json!({
        "trigger": trigger.payload_value(),
        "provider": ExternalProvider::GitHub,
        "direction": ExternalSyncDirection::Pull,
        "conflict_policy": ExternalSyncConflictPolicy::Report,
        "dry_run": false,
    });
    add_recovery(&mut payload, recovered);
    if let Ok(summary) = result {
        payload["stable"] = json!(summary.stable);
        payload["operation_count"] = json!(summary.operation_count);
        payload["applied_operation_count"] = json!(summary.applied_operation_count);
        payload["conflict_count"] = json!(summary.conflict_count);
        payload["snapshot_update_count"] = json!(summary.snapshot_update_count);
    }
    record(db, trigger, payload, result).await;
}

async fn record<T>(
    db: &AsyncDaemonDb,
    trigger: TaskBoardSyncAuditTrigger,
    payload_json: Value,
    result: &Result<T, CliError>,
) {
    record_audit_result_in_db(
        db,
        AuditEventDraft {
            source: "taskBoard",
            category: "taskBoardMutation",
            kind: "task_board.sync",
            action_key: "task_board.sync",
            title: "Sync task-board providers".to_owned(),
            subject: None,
            actor: Some(trigger.actor().to_owned()),
            payload_json: Some(payload_json),
            related_urls: Vec::new(),
        },
        result,
    )
    .await;
}

fn audit_decision(
    db: &AsyncDaemonDb,
    trigger: TaskBoardSyncAuditTrigger,
    error: Option<&CliError>,
    has_applied_change: bool,
) -> AuditDecision {
    let failure_fingerprint = error.map(error_fingerprint);
    let database_fingerprint = fingerprint(db.storage_path());
    let state = BACKGROUND_AUDIT_STATE.get_or_init(|| Mutex::new(BackgroundAuditState::default()));
    state.lock().unwrap_or_else(PoisonError::into_inner).decide(
        database_fingerprint,
        trigger,
        failure_fingerprint,
        has_applied_change,
        Instant::now(),
    )
}

fn error_fingerprint(error: &CliError) -> u64 {
    let mut hasher = DefaultHasher::new();
    error.code().hash(&mut hasher);
    error.message().hash(&mut hasher);
    hasher.finish()
}

fn fingerprint<T: Hash + ?Sized>(value: &T) -> u64 {
    let mut hasher = DefaultHasher::new();
    value.hash(&mut hasher);
    hasher.finish()
}

const fn unstable_projection_decision(has_applied_change: bool) -> AuditDecision {
    if has_applied_change {
        AuditDecision::Record { recovered: false }
    } else {
        AuditDecision::Suppress
    }
}

fn add_recovery(payload: &mut Value, recovered: bool) {
    if recovered {
        payload["recovered"] = json!(true);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::errors::CliErrorKind;
    use crate::task_board::ExternalSyncAction;

    #[test]
    fn requested_sync_always_records_and_background_requires_a_change() {
        let now = Instant::now();
        let mut state = BackgroundAuditState::default();

        assert_eq!(
            state.decide(0, TaskBoardSyncAuditTrigger::Requested, None, false, now),
            AuditDecision::Record { recovered: false }
        );
        assert_eq!(
            state.decide(0, TaskBoardSyncAuditTrigger::Orchestrator, None, false, now),
            AuditDecision::Suppress
        );
        assert_eq!(
            state.decide(
                0,
                TaskBoardSyncAuditTrigger::ReviewsProjection,
                None,
                true,
                now
            ),
            AuditDecision::Record { recovered: false }
        );
    }

    #[test]
    fn background_failure_records_first_changed_and_periodic_occurrences() {
        let now = Instant::now();
        let trigger = TaskBoardSyncAuditTrigger::Orchestrator;
        let mut state = BackgroundAuditState::default();

        assert_eq!(
            state.decide(0, trigger, Some(1), false, now),
            AuditDecision::Record { recovered: false }
        );
        assert_eq!(
            state.decide(0, trigger, Some(1), false, now + Duration::from_secs(1)),
            AuditDecision::Suppress
        );
        assert_eq!(
            state.decide(0, trigger, Some(2), false, now + Duration::from_secs(2)),
            AuditDecision::Record { recovered: false }
        );
        assert_eq!(
            state.decide(0, trigger, Some(1), false, now + Duration::from_secs(3)),
            AuditDecision::Suppress
        );
        assert_eq!(
            state.decide(
                0,
                trigger,
                Some(2),
                false,
                now + Duration::from_secs(2) + BACKGROUND_FAILURE_REPEAT_INTERVAL
            ),
            AuditDecision::Record { recovered: false }
        );
        assert_eq!(state.failures[&(0, trigger)].len(), 1);
    }

    #[test]
    fn failure_fingerprint_distinguishes_messages_with_the_same_error_code() {
        let provider_error: CliError =
            CliErrorKind::workflow_io("provider authentication failed").into();
        let database_error: CliError =
            CliErrorKind::workflow_io("task database unavailable").into();

        assert_eq!(provider_error.code(), database_error.code());
        assert_ne!(
            error_fingerprint(&provider_error),
            error_fingerprint(&database_error)
        );
    }

    #[test]
    fn background_recovery_records_once_even_without_an_applied_change() {
        let now = Instant::now();
        let trigger = TaskBoardSyncAuditTrigger::ReviewsProjection;
        let mut state = BackgroundAuditState::default();

        assert_eq!(
            state.decide(0, trigger, Some(1), false, now),
            AuditDecision::Record { recovered: false }
        );
        assert_eq!(
            state.decide(0, trigger, None, false, now + Duration::from_secs(1)),
            AuditDecision::Record { recovered: true }
        );
        assert_eq!(
            state.decide(0, trigger, None, false, now + Duration::from_secs(2)),
            AuditDecision::Suppress
        );

        let mut payload = json!({});
        add_recovery(&mut payload, true);
        assert_eq!(payload["recovered"], true);
    }

    #[test]
    fn background_health_is_isolated_per_database() {
        let now = Instant::now();
        let trigger = TaskBoardSyncAuditTrigger::ReviewsProjection;
        let mut state = BackgroundAuditState::default();

        assert_eq!(
            state.decide(1, trigger, Some(1), false, now),
            AuditDecision::Record { recovered: false }
        );
        assert_eq!(
            state.decide(2, trigger, None, false, now),
            AuditDecision::Suppress
        );
        assert_eq!(
            state.decide(1, trigger, None, false, now),
            AuditDecision::Record { recovered: true }
        );
    }

    #[test]
    fn unstable_projection_does_not_clear_failure_or_report_recovery() {
        let now = Instant::now();
        let trigger = TaskBoardSyncAuditTrigger::ReviewsProjection;
        let mut state = BackgroundAuditState::default();

        assert_eq!(
            state.decide(0, trigger, Some(1), false, now),
            AuditDecision::Record { recovered: false }
        );
        assert_eq!(unstable_projection_decision(false), AuditDecision::Suppress);
        assert_eq!(
            unstable_projection_decision(true),
            AuditDecision::Record { recovered: false }
        );
        assert_eq!(
            state.decide(0, trigger, None, false, now + Duration::from_secs(1)),
            AuditDecision::Record { recovered: true }
        );
    }

    #[test]
    fn aggregate_payload_contains_counts_without_raw_operations() {
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
        assert_eq!(payload["operation_count"], 2);
        assert_eq!(payload["applied_operation_count"], 1);
        assert_eq!(payload["conflict_count"], 1);
        assert!(payload.get("operations").is_none());
    }

    #[test]
    fn scope_attempt_counts_distinguish_real_sync_from_backoff_noop() {
        let mut payload = json!({});
        add_execution_metrics(
            &mut payload,
            &SyncExecutionMetrics {
                attempted_scope_count: 2,
                result_scope_count: 5,
                succeeded_scope_count: 1,
                failed_scope_count: 1,
                backing_off_scope_count: 3,
                operation_count: 4,
                applied_operation_count: 2,
                conflict_count: 1,
            },
        );

        assert_eq!(payload["attempted_scope_count"], 2);
        assert_eq!(payload["result_scope_count"], 5);
        assert_eq!(payload["succeeded_scope_count"], 1);
        assert_eq!(payload["failed_scope_count"], 1);
        assert_eq!(payload["backing_off_scope_count"], 3);
        assert_eq!(payload["operation_count"], 4);
        assert_eq!(payload["applied_operation_count"], 2);
        assert_eq!(payload["conflict_count"], 1);
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
}
