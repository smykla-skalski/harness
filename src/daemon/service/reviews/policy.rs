use std::path::{Path, PathBuf};
use std::slice::from_ref;
use std::sync::Arc;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::service::observe_async_db;
use crate::daemon::service::reviews::policy_audit::record_policy_run_start_result;
use crate::daemon::service::reviews::policy_enrichment::enrich_policy_target_for_execution;
use crate::daemon::service::reviews::policy_executor::{
    build_policy_provider_registry, daemon_policy_executor_with_audit,
};
use crate::daemon::service::reviews::policy_mapping::{
    map_run_response, preview_step, runtime_trigger_from_reviews,
};
use crate::daemon::service::reviews::preview::{preview_action_target, preview_action_warnings};
use crate::daemon::service::reviews::token::github_token;
use crate::errors::{CliError, CliErrorKind};
use crate::feature_flags;
use crate::reviews::policy::{
    ReviewsPolicyActionExecutor, ReviewsPolicyPlan, authored_reviews_policy_plan,
    planned_reviews_policy_run_matches_target,
};
use crate::reviews::{
    ReviewActionPreviewKind, ReviewItem, ReviewTarget, ReviewsPolicyPreviewRequest,
    ReviewsPolicyPreviewResponse, ReviewsPolicyRunResponse, ReviewsPolicyRunStartRequest,
    ReviewsPolicyStatusRequest, ReviewsPolicyStatusResponse, ReviewsPolicyStepType,
    ReviewsPolicyTrigger,
};
use crate::task_board::github::GitHubMergeMethod;
use crate::task_board::policy_runtime::executor::PolicyRuntimeExecutor;
use crate::task_board::policy_runtime::models::PolicyRunStatus;
use crate::task_board::policy_runtime::repository::PolicyRuntimeRepository;
use crate::task_board::store::default_board_root;

#[cfg(test)]
pub(crate) use super::policy_resume::resume_due_reviews_policy_timers_with_executor_at;
pub(crate) use super::policy_resume::{
    resume_reviews_policy_event, resume_reviews_policy_event_with_executor,
    spawn_reviews_policy_timer_loop,
};

/// Preview the reviews policy plan for one target and report token readiness.
///
/// # Errors
/// Returns `CliError` when the request is invalid or the policy plan cannot be
/// authored for the target.
pub fn preview_reviews_policy(
    request: &ReviewsPolicyPreviewRequest,
) -> Result<ReviewsPolicyPreviewResponse, CliError> {
    let mut response = preview_reviews_policy_with_root(&default_board_root(), request)?;
    if response.eligible
        && preview_response_requires_token(&response)
        && github_token(Some(request.target.repository.as_str()))
            .or_else(|| github_token(None))
            .is_none()
    {
        response.eligible = false;
        response.reason = Some(format!(
            "No GitHub token is configured for '{}'",
            request.target.repository
        ));
    }
    Ok(response)
}

#[cfg_attr(not(test), allow(dead_code))]
pub(crate) fn preview_reviews_policy_with_root(
    root: &Path,
    request: &ReviewsPolicyPreviewRequest,
) -> Result<ReviewsPolicyPreviewResponse, CliError> {
    request.validate()?;
    let preview_target = preview_action_target(ReviewActionPreviewKind::Auto, &request.target);
    let subject = request.subject();
    let workflow_id = request.normalized_workflow_id();
    let plan = authored_reviews_policy_plan(root, &workflow_id, &request.target, request.method)?;
    let mut warnings =
        preview_action_warnings(ReviewActionPreviewKind::Auto, from_ref(&request.target));
    extend_unique(&mut warnings, preview_target.warnings);
    let (eligible, reason) = plan_preview_eligibility(&plan);

    Ok(ReviewsPolicyPreviewResponse {
        workflow_id,
        subject,
        eligible,
        reason,
        warnings,
        steps: plan.steps.iter().map(preview_step).collect(),
    })
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
    let target = enrich_policy_target_for_execution(&request.target).await;
    let request = ReviewsPolicyRunStartRequest {
        target,
        ..request.clone()
    };
    let executor = daemon_policy_executor_with_audit(&request.target.repository, audit_db.clone())?;
    start_reviews_policy_run_with_executor_and_audit_db(
        default_board_root(),
        executor,
        &request,
        audit_db,
    )
    .await
}

pub(crate) async fn start_background_reviews_policy_runs(items: &[ReviewItem]) {
    if !background_reviews_policy_runs_enabled() {
        return;
    }
    let mut started_runs = 0usize;
    for item in items {
        if start_background_reviews_policy_run_for_item(item).await {
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
async fn start_background_reviews_policy_run_for_item(item: &ReviewItem) -> bool {
    let target = enrich_policy_target_for_execution(&item.target()).await;
    let audit_db = observe_async_db();
    let Some(executor) = resolve_background_run_executor(&target, audit_db.clone()) else {
        return false;
    };
    maybe_start_background_reviews_policy_run_with_executor_and_audit_db(
        default_board_root(),
        executor,
        &target,
        GitHubMergeMethod::default(),
        audit_db,
    )
    .await
    .inspect_err(|error| log_background_run_start_error(&target, error))
    .is_ok_and(|started| started.is_some())
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

#[cfg_attr(not(test), allow(dead_code))]
pub(crate) async fn start_reviews_policy_run_with_executor<E>(
    root: PathBuf,
    executor: E,
    request: &ReviewsPolicyRunStartRequest,
) -> Result<ReviewsPolicyRunResponse, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    start_reviews_policy_run_with_executor_and_audit_db(root, executor, request, None).await
}

pub(crate) async fn start_reviews_policy_run_with_executor_and_audit_db<E>(
    root: PathBuf,
    executor: E,
    request: &ReviewsPolicyRunStartRequest,
    audit_db: Option<Arc<AsyncDaemonDb>>,
) -> Result<ReviewsPolicyRunResponse, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let result: Result<ReviewsPolicyRunResponse, CliError> = async {
        request.validate()?;
        reject_disabled_background_request(request)?;
        let workflow_id = request.normalized_workflow_id();
        let plan =
            authored_reviews_policy_plan(&root, &workflow_id, &request.target, request.method)?;
        if !plan.actionable {
            return Err(CliErrorKind::workflow_parse(non_actionable_plan_message(
                &workflow_id,
                &plan,
            ))
            .into());
        }
        let run_request = plan
            .into_run_request()
            .expect("actionable reviews policy plan should produce a run request");

        let providers = build_policy_provider_registry(executor, root.clone());
        let runtime = PolicyRuntimeExecutor::new(PolicyRuntimeRepository::new(root), providers);
        let run = runtime
            .start(runtime_trigger_from_reviews(request.trigger), run_request)
            .await?;
        map_run_response(&run)
    }
    .await;
    record_policy_run_start_result(audit_db.as_ref(), request, &result).await;
    result
}

#[cfg_attr(not(test), allow(dead_code))]
pub(crate) async fn maybe_start_background_reviews_policy_run_with_executor<E>(
    root: PathBuf,
    executor: E,
    target: &ReviewTarget,
    method: GitHubMergeMethod,
) -> Result<Option<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    maybe_start_background_reviews_policy_run_with_executor_and_audit_db(
        root, executor, target, method, None,
    )
    .await
}

pub(crate) async fn maybe_start_background_reviews_policy_run_with_executor_and_audit_db<E>(
    root: PathBuf,
    executor: E,
    target: &ReviewTarget,
    method: GitHubMergeMethod,
    audit_db: Option<Arc<AsyncDaemonDb>>,
) -> Result<Option<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let preview = preview_reviews_policy_with_root(
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
    if terminal_run_matches_target_head(
        &PolicyRuntimeRepository::new(root.clone()),
        &preview.workflow_id,
        target,
    )? {
        return Ok(None);
    }
    start_reviews_policy_run_with_executor_and_audit_db(
        root,
        executor,
        &ReviewsPolicyRunStartRequest {
            workflow_id: preview.workflow_id,
            target: target.clone(),
            method,
            trigger: ReviewsPolicyTrigger::Background,
        },
        audit_db,
    )
    .await
    .map(Some)
}

/// Return the active and recent reviews policy runs for one subject.
///
/// # Errors
/// Returns `CliError` when the request is invalid or the runtime repository
/// cannot read the subject's runs.
pub fn reviews_policy_status(
    request: &ReviewsPolicyStatusRequest,
) -> Result<ReviewsPolicyStatusResponse, CliError> {
    request.validate()?;
    let workflow_id = request.normalized_workflow_id();
    let repository = PolicyRuntimeRepository::new(default_board_root());
    let subject_key = request.subject.subject_key();
    let active_run = repository
        .active_run(&workflow_id, &subject_key)?
        .map(|run| map_run_response(&run))
        .transpose()?;
    let recent_runs = repository
        .runs_for_subject(&workflow_id, &subject_key)?
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

fn plan_preview_eligibility(plan: &ReviewsPolicyPlan) -> (bool, Option<String>) {
    if !plan.actionable {
        return (
            false,
            Some(
                plan.reason.clone().unwrap_or_else(|| {
                    "reviews policy run produced no actionable steps".to_owned()
                }),
            ),
        );
    }
    (true, plan.reason.clone())
}

fn preview_response_requires_token(response: &ReviewsPolicyPreviewResponse) -> bool {
    response
        .steps
        .iter()
        .any(|step| step.step_type == ReviewsPolicyStepType::Action)
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

fn terminal_run_matches_target_head(
    repository: &PolicyRuntimeRepository,
    workflow_id: &str,
    target: &ReviewTarget,
) -> Result<bool, CliError> {
    Ok(repository
        .runs_for_subject(workflow_id, &target.subject_key())?
        .into_iter()
        .any(|run| {
            !matches!(
                run.status,
                PolicyRunStatus::Running | PolicyRunStatus::Waiting
            ) && planned_reviews_policy_run_matches_target(&run.planned_steps, target)
        }))
}

fn extend_unique(target: &mut Vec<String>, additions: Vec<String>) {
    for addition in additions {
        if !target.contains(&addition) {
            target.push(addition);
        }
    }
}

fn non_actionable_plan_message(workflow_id: &str, plan: &ReviewsPolicyPlan) -> String {
    plan.reason.clone().unwrap_or_else(|| {
        format!("reviews policy workflow '{workflow_id}' is not actionable for this pull request")
    })
}
