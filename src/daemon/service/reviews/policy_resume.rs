use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, Utc};
use tokio::task::JoinHandle;
use tokio::time::interval as tokio_interval;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::service::reviews::policy_audit::record_policy_run_resume_result;
use crate::daemon::service::reviews::policy_executor::{
    build_policy_provider_registry, daemon_policy_executor_with_audit,
};
use crate::daemon::service::reviews::policy_mapping::map_run_response;
use crate::errors::{CliError, CliErrorKind};
use crate::reviews::policy::ReviewsPolicyActionExecutor;
use crate::reviews::{ReviewsPolicyRunResponse, ReviewsPolicySubject};
use crate::task_board::policy_graph::{PolicyGraphMode, cached_gate_policy};
use crate::task_board::policy_runtime::executor::PolicyRuntimeExecutor;
use crate::task_board::policy_runtime::models::{
    PolicyRunTrigger, PolicyWorkflowEvent, PolicyWorkflowRun,
};
use crate::task_board::policy_runtime::repository::PolicyRuntimeRepository;
use crate::task_board::store::default_board_root;

use super::policy::background_reviews_policy_runs_enabled;

pub(crate) async fn resume_reviews_policy_event(
    event: &PolicyWorkflowEvent,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError> {
    let subject = ReviewsPolicySubject::from_subject_key(&event.subject_key).ok_or_else(|| {
        CliErrorKind::workflow_parse(format!(
            "reviews policy event subject must be <repository>#<pull_request>: {}",
            event.subject_key
        ))
    })?;
    let audit_db = crate::daemon::service::observe_async_db();
    let executor = daemon_policy_executor_with_audit(&subject.repository, audit_db.clone())?;
    resume_reviews_policy_event_with_executor_and_audit_db(
        default_board_root(),
        executor,
        event,
        audit_db,
    )
    .await
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
    resume_reviews_policy_run_ids_with_executor_and_audit_db(
        root,
        executor,
        &ready_run_ids,
        PolicyRunTrigger::Event,
        None,
    )
    .await
}

pub(crate) async fn resume_reviews_policy_event_with_executor_and_audit_db<E>(
    root: PathBuf,
    executor: E,
    event: &PolicyWorkflowEvent,
    audit_db: Option<Arc<AsyncDaemonDb>>,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let repository = PolicyRuntimeRepository::new(root.clone());
    let ready_run_ids = repository.runs_ready_for_event(event)?;
    resume_reviews_policy_run_ids_with_executor_and_audit_db(
        root,
        executor,
        &ready_run_ids,
        PolicyRunTrigger::Event,
        audit_db,
    )
    .await
}

pub(crate) async fn resume_due_reviews_policy_timers()
-> Result<Vec<ReviewsPolicyRunResponse>, CliError> {
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
    resume_reviews_policy_run_ids_with_executor_and_audit_db(
        root,
        executor,
        &ready_run_ids,
        PolicyRunTrigger::Timer,
        None,
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
        resumed_runs.append(&mut resume_due_reviews_policy_timer_run(&root, &ready_run).await);
    }
    Ok(resumed_runs)
}

async fn resume_due_reviews_policy_timer_run(
    root: &Path,
    ready_run: &PolicyWorkflowRun,
) -> Vec<ReviewsPolicyRunResponse> {
    let Some(subject) = ReviewsPolicySubject::from_subject_key(&ready_run.subject.key) else {
        log_invalid_timer_run_subject(ready_run);
        return Vec::new();
    };
    let audit_db = crate::daemon::service::observe_async_db();
    let Some(executor) = daemon_policy_executor_with_audit(&subject.repository, audit_db.clone())
        .inspect_err(|error| {
            log_timer_run_executor_resolve_error(ready_run, &subject.repository, error)
        })
        .ok()
    else {
        return Vec::new();
    };
    let ready_run_ids = vec![ready_run.run_id.clone()];
    resume_reviews_policy_run_ids_with_executor_and_audit_db(
        root.to_path_buf(),
        executor,
        &ready_run_ids,
        PolicyRunTrigger::Timer,
        audit_db,
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

async fn resume_reviews_policy_run_ids_with_executor_and_audit_db<E>(
    root: PathBuf,
    executor: E,
    run_ids: &[String],
    trigger: PolicyRunTrigger,
    audit_db: Option<Arc<AsyncDaemonDb>>,
) -> Result<Vec<ReviewsPolicyRunResponse>, CliError>
where
    E: ReviewsPolicyActionExecutor + Send + Sync + 'static,
{
    let run_ids = resumable_reviews_policy_run_ids(&root, run_ids)?;
    if run_ids.is_empty() {
        return Ok(Vec::new());
    }
    let providers = build_policy_provider_registry(executor, root.clone());
    let runtime = PolicyRuntimeExecutor::new(PolicyRuntimeRepository::new(root), providers);
    let mut resumed_runs = Vec::with_capacity(run_ids.len());
    for run_id in &run_ids {
        if let Some(run) = runtime.resume(run_id, trigger).await? {
            let response = map_run_response(&run)?;
            record_policy_run_resume_result(audit_db.as_ref(), trigger, &response).await;
            resumed_runs.push(response);
        }
    }
    Ok(resumed_runs)
}

fn resumable_reviews_policy_run_ids(
    root: &Path,
    run_ids: &[String],
) -> Result<Vec<String>, CliError> {
    if !enforced_reviews_policy_active(root) {
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

fn enforced_reviews_policy_active(root: &Path) -> bool {
    cached_gate_policy(root).is_some_and(|document| document.mode == PolicyGraphMode::Enforced)
}
