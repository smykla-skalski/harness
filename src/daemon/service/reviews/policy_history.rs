#[cfg(test)]
use std::path::PathBuf;
use std::sync::Arc;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::service::observe_async_db;
use crate::daemon::service::reviews::policy_mapping::map_run_response;
use crate::errors::CliError;
use crate::reviews::{
    ReviewsPolicyHistoryRequest, ReviewsPolicyHistoryResponse, ReviewsPolicyRunMetrics,
    ReviewsPolicyTimelineEntry,
};
use crate::task_board::policy_runtime::models::{
    PolicyRunMetrics, PolicyWorkflowRun, PolicyWorkflowStepRecord, PolicyWorkflowStepType,
    compute_run_metrics,
};
#[cfg(test)]
use crate::task_board::policy_runtime::repository::PolicyRuntimeRepository;

use super::policy::require_policy_runtime_db;

/// How many runs the history response carries. Bounds the payload so a busy
/// subject cannot flood the observability surface with every retained run.
const HISTORY_RUN_LIMIT: usize = 50;

/// Return the run history, aggregate metrics, and a structured timeline for a
/// reviews policy subject. Backs the daemon observability endpoint so the
/// Monitor app can render run totals and a per-step event log.
///
/// # Errors
/// Returns `CliError` when the request is invalid or a stored run carries a
/// subject key that is not a valid `<repository>#<pull_request>` pair.
pub async fn reviews_policy_history(
    request: &ReviewsPolicyHistoryRequest,
) -> Result<ReviewsPolicyHistoryResponse, CliError> {
    reviews_policy_history_with_audit_db(request, observe_async_db()).await
}

pub(crate) async fn reviews_policy_history_with_audit_db(
    request: &ReviewsPolicyHistoryRequest,
    database: Option<Arc<AsyncDaemonDb>>,
) -> Result<ReviewsPolicyHistoryResponse, CliError> {
    request.validate()?;
    let database = require_policy_runtime_db(database)?;
    let workflow_id = request.normalized_workflow_id();
    let subject_key = request.subject.subject_key();
    let stored_runs = database
        .policy_runs_for_subject(&workflow_id, &subject_key)
        .await?;
    history_response(request, workflow_id, &stored_runs)
}

#[cfg(test)]
pub(crate) fn reviews_policy_history_with_root(
    root: PathBuf,
    request: &ReviewsPolicyHistoryRequest,
) -> Result<ReviewsPolicyHistoryResponse, CliError> {
    request.validate()?;
    let workflow_id = request.normalized_workflow_id();
    let repository = PolicyRuntimeRepository::new(root);
    let subject_key = request.subject.subject_key();

    let stored_runs = repository.runs_for_subject(&workflow_id, &subject_key)?;
    history_response(request, workflow_id, &stored_runs)
}

fn history_response(
    request: &ReviewsPolicyHistoryRequest,
    workflow_id: String,
    stored_runs: &[PolicyWorkflowRun],
) -> Result<ReviewsPolicyHistoryResponse, CliError> {
    let metrics = metrics_response(&compute_run_metrics(stored_runs));
    let timeline = run_timeline(stored_runs);

    let runs = stored_runs
        .iter()
        .take(HISTORY_RUN_LIMIT)
        .map(map_run_response)
        .collect::<Result<Vec<_>, _>>()?;

    Ok(ReviewsPolicyHistoryResponse {
        workflow_id,
        subject: request.subject.clone(),
        runs,
        metrics,
        timeline,
    })
}

fn metrics_response(metrics: &PolicyRunMetrics) -> ReviewsPolicyRunMetrics {
    ReviewsPolicyRunMetrics {
        total: metrics.total,
        running: metrics.running,
        waiting: metrics.waiting,
        completed: metrics.completed,
        failed: metrics.failed,
        cancelled: metrics.cancelled,
        by_trigger: metrics.by_trigger.clone(),
    }
}

/// Flatten every run's recorded steps into one timeline ordered oldest-first
/// so the export reads as a chronological log of what each run did.
fn run_timeline(runs: &[PolicyWorkflowRun]) -> Vec<ReviewsPolicyTimelineEntry> {
    let mut timeline = Vec::new();
    for run in runs {
        for step in &run.steps {
            timeline.push(ReviewsPolicyTimelineEntry {
                recorded_at: step.recorded_at.clone(),
                run_id: run.run_id.clone(),
                event: timeline_event(step),
            });
        }
    }
    timeline.sort_by(|left, right| left.recorded_at.cmp(&right.recorded_at));
    timeline
}

fn timeline_event(step: &PolicyWorkflowStepRecord) -> String {
    match step.step_type {
        PolicyWorkflowStepType::Action => match step.action_key.as_deref() {
            Some(action_key) => format!("action:{action_key}"),
            None => "action".to_owned(),
        },
        PolicyWorkflowStepType::Wait => "wait".to_owned(),
    }
}
