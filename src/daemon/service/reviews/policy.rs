#[cfg(test)]
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::service::observe_async_db;
use crate::daemon::service::reviews::policy_audit::record_policy_run_start_result;
use crate::daemon::service::reviews::policy_enrichment::{
    enrich_policy_target_for_execution, enrich_policy_targets_for_execution,
};
#[cfg(test)]
use crate::daemon::service::reviews::policy_executor::build_policy_provider_registry;
use crate::daemon::service::reviews::policy_executor::{
    build_database_policy_provider_registry, daemon_policy_executor_with_audit,
};
use crate::daemon::service::reviews::policy_mapping::{
    map_run_response, runtime_trigger_from_reviews,
};
#[cfg(test)]
use crate::daemon::service::reviews::policy_plan::preview_legacy_reviews_policy;
use crate::daemon::service::reviews::policy_plan::{
    authored_database_reviews_policy_plan, preview_database_reviews_policy,
    preview_database_reviews_policy_plan,
};
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags;
#[cfg(test)]
use crate::reviews::policy::authored_reviews_policy_plan;
use crate::reviews::policy::{
    ReviewsPolicyActionExecutor, ReviewsPolicyPlan, planned_reviews_policy_run_matches_target,
};
use crate::reviews::{
    ReviewItem, ReviewTarget, ReviewsPolicyPreviewRequest, ReviewsPolicyPreviewResponse,
    ReviewsPolicyRunResponse, ReviewsPolicyRunStartRequest, ReviewsPolicyStatusRequest,
    ReviewsPolicyStatusResponse, ReviewsPolicyTrigger,
};
use crate::task_board::github::GitHubMergeMethod;
use crate::task_board::policy_runtime::executor::PolicyRuntimeExecutor;
use crate::task_board::policy_runtime::models::{
    PolicyRunRequest, PolicyRunStatus, PolicyWorkflowRun,
};
#[cfg(test)]
use crate::task_board::policy_runtime::repository::PolicyRuntimeRepository;

#[cfg(test)]
pub(crate) use super::policy_resume::{
    resume_due_reviews_policy_timers_with_executor_at, resume_reviews_policy_event_with_executor,
};
pub(crate) use super::policy_resume::{
    resume_reviews_policy_event, spawn_reviews_policy_timer_loop,
};

/// Preview the reviews policy plan for one target and report token readiness.
///
/// # Errors
/// Returns `CliError` when the request is invalid or the policy plan cannot be
/// authored for the target.
pub async fn preview_reviews_policy(
    request: &ReviewsPolicyPreviewRequest,
) -> Result<ReviewsPolicyPreviewResponse, CliError> {
    preview_reviews_policy_with_audit_db(request, observe_async_db()).await
}

pub(crate) async fn preview_reviews_policy_with_audit_db(
    request: &ReviewsPolicyPreviewRequest,
    database: Option<Arc<AsyncDaemonDb>>,
) -> Result<ReviewsPolicyPreviewResponse, CliError> {
    let database = require_policy_runtime_db(database)?;
    preview_database_reviews_policy(&database, request).await
}

#[cfg(test)]
pub(crate) fn preview_reviews_policy_with_root(
    root: &Path,
    request: &ReviewsPolicyPreviewRequest,
) -> Result<ReviewsPolicyPreviewResponse, CliError> {
    preview_legacy_reviews_policy(root, request)
}

/// Start a reviews policy run for one target through the daemon executor.
///
/// # Errors
/// Returns `CliError` when the executor cannot be resolved, the request is
/// invalid, the authored plan is not actionable, or the runtime fails to start.
pub async fn start_reviews_policy_run(
    request: &ReviewsPolicyRunStartRequest,
) -> Result<ReviewsPolicyRunResponse, CliError> {
    start_reviews_policy_run_with_audit_db(request, observe_async_db()).await
}

pub(crate) async fn start_reviews_policy_run_with_audit_db(
    request: &ReviewsPolicyRunStartRequest,
    audit_db: Option<Arc<AsyncDaemonDb>>,
) -> Result<ReviewsPolicyRunResponse, CliError> {
    let audit_db = require_policy_runtime_db(audit_db)?;
    let target = enrich_policy_target_for_execution(&request.target).await;
    let request = ReviewsPolicyRunStartRequest {
        target,
        ..request.clone()
    };
    let executor =
        daemon_policy_executor_with_audit(&request.target.repository, Some(Arc::clone(&audit_db)))?;
    start_reviews_policy_run_with_database(executor, &request, audit_db).await
}

pub(crate) async fn start_background_reviews_policy_runs(items: &[ReviewItem]) {
    if !background_reviews_policy_runs_enabled() {
        return;
    }
    let targets = items.iter().map(ReviewItem::target).collect::<Vec<_>>();
    let targets = enrich_policy_targets_for_execution(&targets).await;
    let mut started_runs = 0usize;
    for target in targets {
        if start_background_reviews_policy_run_for_target(&target).await {
            started_runs += 1;
        }
    }
    log_started_background_runs(started_runs);
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_started_background_runs(started_runs: usize) {
    if started_runs > 0 {
        tracing::info!(
            started_run_count = started_runs,
            "started background reviews policy runs"
        );
    }
}

/// Resolve the executor for one review item and attempt a background policy run.
/// Returns `true` only when a run was actually started; resolve and start
/// failures are logged and reported as `false`.
async fn start_background_reviews_policy_run_for_target(target: &ReviewTarget) -> bool {
    let Ok(audit_db) = require_policy_runtime_db(observe_async_db()).inspect_err(|error| {
        log_background_runtime_database_error(target, error);
    }) else {
        return false;
    };
    let Some(executor) = resolve_background_run_executor(target, Some(Arc::clone(&audit_db)))
    else {
        return false;
    };
    maybe_start_background_reviews_policy_run_with_database(
        executor,
        target,
        GitHubMergeMethod::default(),
        audit_db,
    )
    .await
    .inspect_err(|error| log_background_run_start_error(target, error))
    .is_ok_and(|started| started.is_some())
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_background_runtime_database_error(target: &ReviewTarget, error: &CliError) {
    tracing::warn!(
        repository = %target.repository,
        pull_request = target.number,
        error = %error,
        "reviews policy runtime database is unavailable"
    );
}

fn resolve_background_run_executor(
    target: &ReviewTarget,
    audit_db: Option<Arc<AsyncDaemonDb>>,
) -> Option<impl ReviewsPolicyActionExecutor + 'static> {
    daemon_policy_executor_with_audit(&target.repository, audit_db)
        .inspect_err(|error| log_background_executor_resolve_error(target, error))
        .ok()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_background_executor_resolve_error(target: &ReviewTarget, error: &CliError) {
    tracing::warn!(
        repository = %target.repository,
        pull_request = target.number,
        error = %error,
        "failed to resolve executor for background reviews policy run"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_background_run_start_error(target: &ReviewTarget, error: &CliError) {
    tracing::warn!(
        repository = %target.repository,
        pull_request = target.number,
        error = %error,
        "failed to start background reviews policy run"
    );
}

async fn start_reviews_policy_run_with_database<E>(
    executor: E,
    request: &ReviewsPolicyRunStartRequest,
    database: Arc<AsyncDaemonDb>,
) -> Result<ReviewsPolicyRunResponse, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let result: Result<ReviewsPolicyRunResponse, CliError> = async {
        request.validate()?;
        reject_disabled_background_request(request)?;
        let workflow_id = request.normalized_workflow_id();
        let plan = authored_database_reviews_policy_plan(
            &database,
            &workflow_id,
            &request.target,
            request.method,
        )
        .await?;
        start_actionable_database_run(executor, request, workflow_id, plan, &database).await
    }
    .await;
    record_policy_run_start_result(Some(&database), request, &result).await;
    result
}

async fn start_actionable_database_run<E>(
    executor: E,
    request: &ReviewsPolicyRunStartRequest,
    workflow_id: String,
    plan: ReviewsPolicyPlan,
    database: &Arc<AsyncDaemonDb>,
) -> Result<ReviewsPolicyRunResponse, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let run_request = actionable_run_request(&workflow_id, plan)?;
    let providers = build_database_policy_provider_registry(executor, Arc::clone(database));
    let runtime = PolicyRuntimeExecutor::new_database(Arc::clone(database), providers);
    let run = runtime
        .start(runtime_trigger_from_reviews(request.trigger), run_request)
        .await?;
    map_run_response(&run)
}

#[cfg(test)]
pub(crate) async fn start_reviews_policy_run_with_executor<E>(
    root: PathBuf,
    executor: E,
    request: &ReviewsPolicyRunStartRequest,
) -> Result<ReviewsPolicyRunResponse, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    request.validate()?;
    reject_disabled_background_request(request)?;
    let workflow_id = request.normalized_workflow_id();
    let plan = authored_reviews_policy_plan(&root, &workflow_id, &request.target, request.method)?;
    let run_request = actionable_run_request(&workflow_id, plan)?;
    let providers = build_policy_provider_registry(executor, root.clone());
    let runtime = PolicyRuntimeExecutor::new(PolicyRuntimeRepository::new(root), providers);
    let run = runtime
        .start(runtime_trigger_from_reviews(request.trigger), run_request)
        .await?;
    map_run_response(&run)
}

#[cfg(test)]
pub(crate) async fn start_reviews_policy_run_with_executor_and_audit_db<E>(
    root: PathBuf,
    executor: E,
    request: &ReviewsPolicyRunStartRequest,
    audit_db: Option<Arc<AsyncDaemonDb>>,
) -> Result<ReviewsPolicyRunResponse, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let result = start_reviews_policy_run_with_executor(root, executor, request).await;
    record_policy_run_start_result(audit_db.as_ref(), request, &result).await;
    result
}

#[cfg(test)]
pub(crate) async fn maybe_start_background_reviews_policy_run_with_executor<E>(
    root: PathBuf,
    executor: E,
    target: &ReviewTarget,
    method: GitHubMergeMethod,
) -> Result<Option<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let preview = preview_legacy_reviews_policy(
        &root,
        &ReviewsPolicyPreviewRequest {
            workflow_id: String::new(),
            target: target.clone(),
            method,
        },
    )?;
    if !preview.eligible {
        return Ok(None);
    }
    if terminal_legacy_run_matches_target_head(&root, &preview.workflow_id, target)? {
        return Ok(None);
    }
    start_reviews_policy_run_with_executor(
        root,
        executor,
        &ReviewsPolicyRunStartRequest {
            workflow_id: preview.workflow_id,
            target: target.clone(),
            method,
            trigger: ReviewsPolicyTrigger::Background,
        },
    )
    .await
    .map(Some)
}

async fn maybe_start_background_reviews_policy_run_with_database<E>(
    executor: E,
    target: &ReviewTarget,
    method: GitHubMergeMethod,
    database: Arc<AsyncDaemonDb>,
) -> Result<Option<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let preview = preview_database_reviews_policy_plan(
        &database,
        &ReviewsPolicyPreviewRequest {
            workflow_id: String::new(),
            target: target.clone(),
            method,
        },
    )
    .await?;
    if !preview.eligible
        || terminal_database_run_matches_target_head(&database, &preview.workflow_id, target)
            .await?
    {
        return Ok(None);
    }
    start_reviews_policy_run_with_database(
        executor,
        &ReviewsPolicyRunStartRequest {
            workflow_id: preview.workflow_id,
            target: target.clone(),
            method,
            trigger: ReviewsPolicyTrigger::Background,
        },
        database,
    )
    .await
    .map(Some)
}

/// Return the active and recent reviews policy runs for one subject.
///
/// # Errors
/// Returns `CliError` when the request is invalid or the runtime repository
/// cannot read the subject's runs.
pub async fn reviews_policy_status(
    request: &ReviewsPolicyStatusRequest,
) -> Result<ReviewsPolicyStatusResponse, CliError> {
    reviews_policy_status_with_audit_db(request, observe_async_db()).await
}

pub(crate) async fn reviews_policy_status_with_audit_db(
    request: &ReviewsPolicyStatusRequest,
    database: Option<Arc<AsyncDaemonDb>>,
) -> Result<ReviewsPolicyStatusResponse, CliError> {
    request.validate()?;
    let database = require_policy_runtime_db(database)?;
    let workflow_id = request.normalized_workflow_id();
    let subject_key = request.subject.subject_key();
    let active_run = database
        .active_policy_runs_for_subject(&workflow_id, &subject_key)
        .await?
        .into_iter()
        .next()
        .map(|run| map_run_response(&run))
        .transpose()?;
    let recent_runs = database
        .policy_runs_for_subject(&workflow_id, &subject_key)
        .await?
        .into_iter()
        .map(|run| map_run_response(&run))
        .collect::<Result<Vec<_>, _>>()?;

    Ok(ReviewsPolicyStatusResponse {
        workflow_id,
        subject: request.subject.clone(),
        active_run,
        recent_runs,
    })
}

pub(super) fn background_reviews_policy_runs_enabled() -> bool {
    feature_flags::reviews_background_auto_enabled_from_env()
}

fn reject_disabled_background_request(
    request: &ReviewsPolicyRunStartRequest,
) -> Result<(), CliError> {
    if request.trigger != ReviewsPolicyTrigger::Background
        || background_reviews_policy_runs_enabled()
    {
        return Ok(());
    }
    Err(CliErrorKind::workflow_parse(format!(
        "background reviews policy runs are disabled; set {}=1 to allow background GitHub mutations",
        feature_flags::REVIEWS_BACKGROUND_AUTO_ENV
    ))
    .into())
}

async fn terminal_database_run_matches_target_head(
    database: &AsyncDaemonDb,
    workflow_id: &str,
    target: &ReviewTarget,
) -> Result<bool, CliError> {
    let runs = database
        .policy_runs_for_subject(workflow_id, &target.subject_key())
        .await?;
    Ok(terminal_run_matches_target(&runs, target))
}

#[cfg(test)]
fn terminal_legacy_run_matches_target_head(
    root: &Path,
    workflow_id: &str,
    target: &ReviewTarget,
) -> Result<bool, CliError> {
    let runs = PolicyRuntimeRepository::new(root.to_path_buf())
        .runs_for_subject(workflow_id, &target.subject_key())?;
    Ok(terminal_run_matches_target(&runs, target))
}

fn terminal_run_matches_target(runs: &[PolicyWorkflowRun], target: &ReviewTarget) -> bool {
    runs.iter().any(|run| {
        !matches!(
            run.status,
            PolicyRunStatus::Running | PolicyRunStatus::Waiting
        ) && planned_reviews_policy_run_matches_target(&run.planned_steps, target)
    })
}

pub(super) fn require_policy_runtime_db(
    database: Option<Arc<AsyncDaemonDb>>,
) -> Result<Arc<AsyncDaemonDb>, CliError> {
    database.ok_or_else(|| {
        CliErrorKind::workflow_io("reviews policy runtime database is unavailable").into()
    })
}

fn actionable_run_request(
    workflow_id: &str,
    plan: ReviewsPolicyPlan,
) -> Result<PolicyRunRequest, CliError> {
    if !plan.actionable {
        return Err(
            CliErrorKind::workflow_parse(non_actionable_plan_message(workflow_id, &plan)).into(),
        );
    }
    Ok(plan
        .into_run_request()
        .expect("actionable reviews policy plan should produce a run request"))
}

fn non_actionable_plan_message(workflow_id: &str, plan: &ReviewsPolicyPlan) -> String {
    plan.reason.clone().unwrap_or_else(|| {
        format!("reviews policy workflow '{workflow_id}' is not actionable for this pull request")
    })
}
