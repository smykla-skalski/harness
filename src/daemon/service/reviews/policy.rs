use std::path::PathBuf;
use std::time::Duration;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use tokio::task::JoinHandle;
use tokio::time::interval as tokio_interval;

use crate::daemon::service::reviews::preview::{preview_action_target, preview_action_warnings};
use crate::daemon::service::reviews::token::{github_token, missing_token_error};
use crate::errors::{CliError, CliErrorKind};
use crate::reviews::policy::{
    ReviewsPolicyActionExecutor, ReviewsPolicyPlan, ReviewsPolicyProvider,
    authored_reviews_policy_plan, planned_reviews_policy_run_matches_target,
};
use crate::reviews::{
    ReviewActionPreviewKind, ReviewItem, ReviewTarget, ReviewsGitHubClient,
    ReviewsPolicyPreviewRequest, ReviewsPolicyPreviewResponse, ReviewsPolicyPreviewStep,
    ReviewsPolicyRunResponse, ReviewsPolicyRunStartRequest, ReviewsPolicyRunStatus,
    ReviewsPolicyRunStep, ReviewsPolicyStatusRequest, ReviewsPolicyStatusResponse,
    ReviewsPolicyStepType, ReviewsPolicySubject, ReviewsPolicyTrigger, ReviewsPolicyWait,
};
use crate::task_board::github::GitHubMergeMethod;
use crate::task_board::policy_graph::PolicyWaitCondition;
use crate::task_board::policy_runtime::executor::PolicyRuntimeExecutor;
use crate::task_board::policy_runtime::models::{
    PolicyRunStatus, PolicyRunStep, PolicyRunTrigger, PolicyWorkflowEvent, PolicyWorkflowRun,
    PolicyWorkflowStepType,
};
use crate::task_board::policy_runtime::providers::PolicyProviderRegistry;
use crate::task_board::policy_runtime::repository::PolicyRuntimeRepository;
use crate::task_board::store::default_board_root;

pub fn preview_reviews_policy(
    request: &ReviewsPolicyPreviewRequest,
) -> Result<ReviewsPolicyPreviewResponse, CliError> {
    let mut response = preview_reviews_policy_with_root(default_board_root(), request)?;
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
    root: PathBuf,
    request: &ReviewsPolicyPreviewRequest,
) -> Result<ReviewsPolicyPreviewResponse, CliError> {
    request.validate()?;
    let preview_target = preview_action_target(ReviewActionPreviewKind::Auto, &request.target);
    let subject = request.subject();
    let workflow_id = request.normalized_workflow_id();
    let plan = authored_reviews_policy_plan(root, &workflow_id, &request.target, request.method)?;
    let mut warnings =
        preview_action_warnings(ReviewActionPreviewKind::Auto, &[request.target.clone()]);
    extend_unique(&mut warnings, preview_target.warnings.clone());
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

pub async fn start_reviews_policy_run(
    request: &ReviewsPolicyRunStartRequest,
) -> Result<ReviewsPolicyRunResponse, CliError> {
    let executor = daemon_policy_executor(&request.target.repository)?;
    start_reviews_policy_run_with_executor(default_board_root(), executor, request).await
}

pub(crate) async fn start_background_reviews_policy_runs(items: &[ReviewItem]) {
    let mut started_runs = 0usize;
    for item in items {
        let target = item.target();
        let executor = match daemon_policy_executor(&target.repository) {
            Ok(executor) => executor,
            Err(error) => {
                tracing::warn!(
                    repository = %target.repository,
                    pull_request = target.number,
                    error = %error,
                    "failed to resolve executor for background reviews policy run"
                );
                continue;
            }
        };
        match maybe_start_background_reviews_policy_run_with_executor(
            default_board_root(),
            executor,
            &target,
            GitHubMergeMethod::default(),
        )
        .await
        {
            Ok(Some(_)) => started_runs += 1,
            Ok(None) => {}
            Err(error) => {
                tracing::warn!(
                    repository = %target.repository,
                    pull_request = target.number,
                    error = %error,
                    "failed to start background reviews policy run"
                );
            }
        }
    }
    if started_runs > 0 {
        tracing::info!(
            started_run_count = started_runs,
            "started background reviews policy runs"
        );
    }
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
    request.validate()?;
    let workflow_id = request.normalized_workflow_id();
    let plan =
        authored_reviews_policy_plan(root.clone(), &workflow_id, &request.target, request.method)?;
    if !plan.actionable {
        return Err(
            CliErrorKind::workflow_parse(non_actionable_plan_message(&workflow_id, &plan)).into(),
        );
    }
    let run_request = plan
        .into_run_request()
        .expect("actionable reviews policy plan should produce a run request");

    let mut providers = PolicyProviderRegistry::default();
    providers.register(ReviewsPolicyProvider::new(executor));
    let runtime = PolicyRuntimeExecutor::new(PolicyRuntimeRepository::new(root), providers);
    let run = runtime
        .start(runtime_trigger_from_reviews(request.trigger), run_request)
        .await?;
    map_run_response(&run)
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
    let preview = preview_reviews_policy_with_root(
        root.clone(),
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

pub async fn resume_reviews_policy_event(
    event: &PolicyWorkflowEvent,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError> {
    let subject = ReviewsPolicySubject::from_subject_key(&event.subject_key).ok_or_else(|| {
        CliErrorKind::workflow_parse(format!(
            "reviews policy event subject must be <repository>#<pull_request>: {}",
            event.subject_key
        ))
    })?;
    let executor = daemon_policy_executor(&subject.repository)?;
    resume_reviews_policy_event_with_executor(default_board_root(), executor, event).await
}

#[cfg_attr(not(test), allow(dead_code))]
pub(crate) async fn resume_reviews_policy_event_with_executor<E>(
    root: PathBuf,
    executor: E,
    event: &PolicyWorkflowEvent,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let repository = PolicyRuntimeRepository::new(root.clone());
    let ready_run_ids = repository.runs_ready_for_event(event)?;
    resume_reviews_policy_run_ids_with_executor(
        root,
        executor,
        &ready_run_ids,
        PolicyRunTrigger::Event,
    )
    .await
}

pub async fn resume_due_reviews_policy_timers() -> Result<Vec<ReviewsPolicyRunResponse>, CliError> {
    resume_due_reviews_policy_timers_at(default_board_root(), Utc::now()).await
}

#[cfg_attr(not(test), allow(dead_code))]
pub(crate) async fn resume_due_reviews_policy_timers_with_executor_at<E>(
    root: PathBuf,
    executor: E,
    now: DateTime<Utc>,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let ready_run_ids = PolicyRuntimeRepository::new(root.clone())
        .runs_ready_for_timer(now)?
        .into_iter()
        .map(|run| run.run_id)
        .collect::<Vec<_>>();
    resume_reviews_policy_run_ids_with_executor(
        root,
        executor,
        &ready_run_ids,
        PolicyRunTrigger::Timer,
    )
    .await
}

pub(crate) fn spawn_reviews_policy_timer_loop(interval: Duration) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = tokio_interval(interval);
        loop {
            ticker.tick().await;
            match resume_due_reviews_policy_timers().await {
                Ok(resumed_runs) => {
                    if !resumed_runs.is_empty() {
                        tracing::info!(
                            resumed_run_count = resumed_runs.len(),
                            "resumed due reviews policy timer runs"
                        );
                    }
                }
                Err(error) => {
                    tracing::warn!(%error, "failed to resume due reviews policy timer runs");
                }
            }
        }
    })
}

async fn resume_due_reviews_policy_timers_at(
    root: PathBuf,
    now: DateTime<Utc>,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError> {
    let ready_runs = PolicyRuntimeRepository::new(root.clone()).runs_ready_for_timer(now)?;
    let mut resumed_runs = Vec::with_capacity(ready_runs.len());
    for ready_run in ready_runs {
        let Some(subject) = ReviewsPolicySubject::from_subject_key(&ready_run.subject.key) else {
            tracing::warn!(
                run_id = %ready_run.run_id,
                subject_key = %ready_run.subject.key,
                "skipping due reviews policy timer run with invalid subject"
            );
            continue;
        };
        let executor = match daemon_policy_executor(&subject.repository) {
            Ok(executor) => executor,
            Err(error) => {
                tracing::warn!(
                    run_id = %ready_run.run_id,
                    repository = %subject.repository,
                    error = %error,
                    "failed to resolve executor for due reviews policy timer run"
                );
                continue;
            }
        };
        let ready_run_ids = vec![ready_run.run_id.clone()];
        match resume_reviews_policy_run_ids_with_executor(
            root.clone(),
            executor,
            &ready_run_ids,
            PolicyRunTrigger::Timer,
        )
        .await
        {
            Ok(mut resumed) => resumed_runs.append(&mut resumed),
            Err(error) => {
                tracing::warn!(
                    run_id = %ready_run.run_id,
                    error = %error,
                    "failed to resume due reviews policy timer run"
                );
            }
        }
    }
    Ok(resumed_runs)
}

async fn resume_reviews_policy_run_ids_with_executor<E>(
    root: PathBuf,
    executor: E,
    run_ids: &[String],
    trigger: PolicyRunTrigger,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    if run_ids.is_empty() {
        return Ok(Vec::new());
    }
    let mut providers = PolicyProviderRegistry::default();
    providers.register(ReviewsPolicyProvider::new(executor));
    let runtime = PolicyRuntimeExecutor::new(PolicyRuntimeRepository::new(root), providers);
    let mut resumed_runs = Vec::with_capacity(run_ids.len());
    for run_id in run_ids {
        if let Some(run) = runtime.resume(run_id, trigger).await? {
            resumed_runs.push(map_run_response(&run)?);
        }
    }
    Ok(resumed_runs)
}

fn daemon_policy_executor(repository: &str) -> Result<DaemonReviewsPolicyExecutor, CliError> {
    let token = github_token(Some(repository))
        .or_else(|| github_token(None))
        .ok_or_else(|| missing_token_error(Some(repository)))?;
    Ok(DaemonReviewsPolicyExecutor {
        client: ReviewsGitHubClient::new(&token)?,
    })
}

fn preview_step(step: &PolicyRunStep) -> ReviewsPolicyPreviewStep {
    match step {
        PolicyRunStep::Action(action) => ReviewsPolicyPreviewStep {
            step_type: ReviewsPolicyStepType::Action,
            action_key: Some(action.action_key.clone()),
            waiting_on: None,
        },
        PolicyRunStep::Wait(wait) => ReviewsPolicyPreviewStep {
            step_type: ReviewsPolicyStepType::Wait,
            action_key: None,
            waiting_on: Some(wait_response(wait)),
        },
    }
}

fn wait_response(wait: &PolicyWaitCondition) -> ReviewsPolicyWait {
    match wait {
        PolicyWaitCondition::Event { event_key } => ReviewsPolicyWait {
            event_key: Some(event_key.clone()),
            duration_seconds: None,
        },
        PolicyWaitCondition::Timer { duration_seconds } => ReviewsPolicyWait {
            event_key: None,
            duration_seconds: Some(*duration_seconds),
        },
    }
}

fn map_run_response(run: &PolicyWorkflowRun) -> Result<ReviewsPolicyRunResponse, CliError> {
    let subject = ReviewsPolicySubject::from_subject_key(&run.subject.key).ok_or_else(|| {
        CliErrorKind::workflow_parse(format!(
            "reviews policy run subject must be <repository>#<pull_request>: {}",
            run.subject.key
        ))
    })?;

    Ok(ReviewsPolicyRunResponse {
        workflow_id: run.workflow_id.clone(),
        run_id: run.run_id.clone(),
        subject,
        trigger: reviews_trigger_from_runtime(run.trigger),
        status: reviews_status_from_runtime(run.status),
        started_at: run.created_at.clone(),
        updated_at: run.updated_at.clone(),
        waiting_on: run.waiting_on.as_ref().map(wait_response),
        completed_at: run.completed_at.clone(),
        error_message: run.error_message.clone(),
        steps: run
            .steps
            .iter()
            .map(|step| ReviewsPolicyRunStep {
                step_type: reviews_step_type_from_runtime(step.step_type),
                action_key: step.action_key.clone(),
                waiting_on: step.waiting_on.as_ref().map(wait_response),
                recorded_at: step.recorded_at.clone(),
            })
            .collect(),
    })
}

fn reviews_status_from_runtime(status: PolicyRunStatus) -> ReviewsPolicyRunStatus {
    match status {
        PolicyRunStatus::Cancelled => ReviewsPolicyRunStatus::Cancelled,
        PolicyRunStatus::Completed => ReviewsPolicyRunStatus::Completed,
        PolicyRunStatus::Failed => ReviewsPolicyRunStatus::Failed,
        PolicyRunStatus::Running => ReviewsPolicyRunStatus::Running,
        PolicyRunStatus::Waiting => ReviewsPolicyRunStatus::Waiting,
    }
}

fn reviews_trigger_from_runtime(trigger: PolicyRunTrigger) -> ReviewsPolicyTrigger {
    match trigger {
        PolicyRunTrigger::Background => ReviewsPolicyTrigger::Background,
        PolicyRunTrigger::Event => ReviewsPolicyTrigger::Event,
        PolicyRunTrigger::Manual => ReviewsPolicyTrigger::Manual,
        PolicyRunTrigger::ManualNudge => ReviewsPolicyTrigger::ManualNudge,
        PolicyRunTrigger::Timer => ReviewsPolicyTrigger::Timer,
    }
}

fn runtime_trigger_from_reviews(trigger: ReviewsPolicyTrigger) -> PolicyRunTrigger {
    match trigger {
        ReviewsPolicyTrigger::Background => PolicyRunTrigger::Background,
        ReviewsPolicyTrigger::Event => PolicyRunTrigger::Event,
        ReviewsPolicyTrigger::Manual => PolicyRunTrigger::Manual,
        ReviewsPolicyTrigger::ManualNudge => PolicyRunTrigger::ManualNudge,
        ReviewsPolicyTrigger::Timer => PolicyRunTrigger::Timer,
    }
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

fn reviews_step_type_from_runtime(step_type: PolicyWorkflowStepType) -> ReviewsPolicyStepType {
    match step_type {
        PolicyWorkflowStepType::Action => ReviewsPolicyStepType::Action,
        PolicyWorkflowStepType::Wait => ReviewsPolicyStepType::Wait,
    }
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

struct DaemonReviewsPolicyExecutor {
    client: ReviewsGitHubClient,
}

#[async_trait]
impl ReviewsPolicyActionExecutor for DaemonReviewsPolicyExecutor {
    async fn approve(&self, target: &ReviewTarget) -> Result<(), CliError> {
        self.client.policy_approve(target).await
    }

    async fn merge(
        &self,
        target: &ReviewTarget,
        method: GitHubMergeMethod,
    ) -> Result<(), CliError> {
        self.client.policy_merge(target, method).await
    }
}
