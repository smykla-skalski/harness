#[cfg(test)]
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use tokio::task::JoinHandle;
use tokio::time::interval as tokio_interval;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::service::observe_async_db;
use crate::daemon::service::reviews::policy_audit::record_policy_run_resume_result;
#[cfg(test)]
use crate::daemon::service::reviews::policy_executor::build_policy_provider_registry;
use crate::daemon::service::reviews::policy_executor::{
    build_database_policy_provider_registry, daemon_policy_executor_with_audit,
};
use crate::daemon::service::reviews::policy_mapping::map_run_response;
use crate::daemon::service::reviews::policy_plan::enforced_database_reviews_policy_active;
use crate::errors::{CliError, CliErrorKind};
use crate::reviews::policy::ReviewsPolicyActionExecutor;
use crate::reviews::{ReviewsPolicyRunResponse, ReviewsPolicySubject};
#[cfg(test)]
use crate::task_board::policy_graph::{PolicyGraphMode, cached_gate_policy};
use crate::task_board::policy_runtime::executor::PolicyRuntimeExecutor;
use crate::task_board::policy_runtime::models::{
    PolicyRunTrigger, PolicyWorkflowEvent, PolicyWorkflowRun,
};
#[cfg(test)]
use crate::task_board::policy_runtime::repository::PolicyRuntimeRepository;

use super::policy::{background_reviews_policy_runs_enabled, require_policy_runtime_db};

pub(crate) async fn resume_reviews_policy_event(
    event: &PolicyWorkflowEvent,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError> {
    let subject = ReviewsPolicySubject::from_subject_key(&event.subject_key).ok_or_else(|| {
        CliErrorKind::workflow_parse(format!(
            "reviews policy event subject must be <repository>#<pull_request>: {}",
            event.subject_key
        ))
    })?;
    let audit_db = require_policy_runtime_db(observe_async_db())?;
    let executor =
        daemon_policy_executor_with_audit(&subject.repository, Some(Arc::clone(&audit_db)))?;
    resume_reviews_policy_event_with_executor_and_database(executor, event, audit_db).await
}

#[cfg(test)]
pub(crate) async fn resume_reviews_policy_event_with_executor<E>(
    root: PathBuf,
    executor: E,
    event: &PolicyWorkflowEvent,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let ready_run_ids = PolicyRuntimeRepository::new(root.clone()).runs_ready_for_event(event)?;
    resume_legacy_reviews_policy_run_ids(root, executor, &ready_run_ids, PolicyRunTrigger::Event)
        .await
}

pub(crate) async fn resume_reviews_policy_event_with_executor_and_database<E>(
    executor: E,
    event: &PolicyWorkflowEvent,
    database: Arc<AsyncDaemonDb>,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let ready_run_ids = database.policy_run_ids_ready_for_event(event).await?;
    resume_database_reviews_policy_run_ids(
        executor,
        &ready_run_ids,
        PolicyRunTrigger::Event,
        database,
    )
    .await
}

pub(crate) async fn resume_due_reviews_policy_timers()
-> Result<Vec<ReviewsPolicyRunResponse>, CliError> {
    let database = require_policy_runtime_db(observe_async_db())?;
    resume_due_reviews_policy_timers_at(database, Utc::now()).await
}

#[cfg(test)]
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
    resume_legacy_reviews_policy_run_ids(root, executor, &ready_run_ids, PolicyRunTrigger::Timer)
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
    database: Arc<AsyncDaemonDb>,
    now: DateTime<Utc>,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError> {
    let ready_runs = database.policy_runs_ready_for_timer(now).await?;
    let mut resumed_runs = Vec::with_capacity(ready_runs.len());
    for ready_run in ready_runs {
        resumed_runs.append(
            &mut resume_due_reviews_policy_timer_run(&ready_run, Arc::clone(&database)).await,
        );
    }
    Ok(resumed_runs)
}

async fn resume_due_reviews_policy_timer_run(
    ready_run: &PolicyWorkflowRun,
    database: Arc<AsyncDaemonDb>,
) -> Vec<ReviewsPolicyRunResponse> {
    let Some(subject) = ReviewsPolicySubject::from_subject_key(&ready_run.subject.key) else {
        log_invalid_timer_run_subject(ready_run);
        return Vec::new();
    };
    let Some(executor) =
        daemon_policy_executor_with_audit(&subject.repository, Some(Arc::clone(&database)))
            .inspect_err(|error| {
                log_timer_run_executor_resolve_error(ready_run, &subject.repository, error);
            })
            .ok()
    else {
        return Vec::new();
    };
    let ready_run_ids = vec![ready_run.run_id.clone()];
    resume_database_reviews_policy_run_ids(
        executor,
        &ready_run_ids,
        PolicyRunTrigger::Timer,
        database,
    )
    .await
    .inspect_err(|error| log_timer_run_resume_error(ready_run, error))
    .unwrap_or_default()
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_invalid_timer_run_subject(ready_run: &PolicyWorkflowRun) {
    tracing::warn!(
        run_id = %ready_run.run_id,
        subject_key = %ready_run.subject.key,
        "skipping due reviews policy timer run with invalid subject"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_timer_run_executor_resolve_error(
    ready_run: &PolicyWorkflowRun,
    repository: &str,
    error: &CliError,
) {
    tracing::warn!(
        run_id = %ready_run.run_id,
        repository = %repository,
        error = %error,
        "failed to resolve executor for due reviews policy timer run"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing macro expansion; tokio-rs/tracing#553"
)]
fn log_timer_run_resume_error(ready_run: &PolicyWorkflowRun, error: &CliError) {
    tracing::warn!(
        run_id = %ready_run.run_id,
        error = %error,
        "failed to resume due reviews policy timer run"
    );
}

async fn resume_database_reviews_policy_run_ids<E>(
    executor: E,
    run_ids: &[String],
    trigger: PolicyRunTrigger,
    database: Arc<AsyncDaemonDb>,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let run_ids = resumable_database_reviews_policy_run_ids(&database, run_ids).await?;
    if run_ids.is_empty() {
        return Ok(Vec::new());
    }
    let providers = build_database_policy_provider_registry(executor, Arc::clone(&database));
    let runtime = PolicyRuntimeExecutor::new_database(Arc::clone(&database), providers);
    resume_policy_run_ids(&runtime, &run_ids, trigger, Some(&database)).await
}

#[cfg(test)]
async fn resume_legacy_reviews_policy_run_ids<E>(
    root: PathBuf,
    executor: E,
    run_ids: &[String],
    trigger: PolicyRunTrigger,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let run_ids = resumable_legacy_reviews_policy_run_ids(&root, run_ids)?;
    if run_ids.is_empty() {
        return Ok(Vec::new());
    }
    let providers = build_policy_provider_registry(executor, root.clone());
    let runtime = PolicyRuntimeExecutor::new(PolicyRuntimeRepository::new(root), providers);
    resume_policy_run_ids(&runtime, &run_ids, trigger, None).await
}

async fn resume_policy_run_ids(
    runtime: &PolicyRuntimeExecutor,
    run_ids: &[String],
    trigger: PolicyRunTrigger,
    database: Option<&Arc<AsyncDaemonDb>>,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError> {
    let mut resumed_runs = Vec::with_capacity(run_ids.len());
    for run_id in run_ids {
        if let Some(run) = runtime.resume(run_id, trigger).await? {
            let response = map_run_response(&run)?;
            record_policy_run_resume_result(database, trigger, &response).await;
            resumed_runs.push(response);
        }
    }
    Ok(resumed_runs)
}

async fn resumable_database_reviews_policy_run_ids(
    database: &AsyncDaemonDb,
    run_ids: &[String],
) -> Result<Vec<String>, CliError> {
    if !enforced_database_reviews_policy_active(database).await? {
        return Ok(Vec::new());
    }
    if background_reviews_policy_runs_enabled() {
        return Ok(run_ids.to_vec());
    }
    let mut resumable = Vec::with_capacity(run_ids.len());
    for run_id in run_ids {
        let Some(run) = database.policy_run_by_id(run_id).await? else {
            continue;
        };
        if run.trigger != PolicyRunTrigger::Background {
            resumable.push(run_id.clone());
        }
    }
    Ok(resumable)
}

#[cfg(test)]
fn resumable_legacy_reviews_policy_run_ids(
    root: &Path,
    run_ids: &[String],
) -> Result<Vec<String>, CliError> {
    if !enforced_legacy_reviews_policy_active(root) {
        return Ok(Vec::new());
    }
    if background_reviews_policy_runs_enabled() {
        return Ok(run_ids.to_vec());
    }
    let repository = PolicyRuntimeRepository::new(root.to_path_buf());
    let mut resumable = Vec::with_capacity(run_ids.len());
    for run_id in run_ids {
        let Some(run) = repository.run_by_id(run_id)? else {
            continue;
        };
        if run.trigger != PolicyRunTrigger::Background {
            resumable.push(run_id.clone());
        }
    }
    Ok(resumable)
}

#[cfg(test)]
fn enforced_legacy_reviews_policy_active(root: &Path) -> bool {
    cached_gate_policy(root).is_some_and(|document| document.mode == PolicyGraphMode::Enforced)
}
