use std::ops::ControlFlow;
use std::sync::Arc;

use chrono::Utc;
use tracing::{info, warn};

use crate::daemon::db::AsyncDaemonDb;
use crate::errors::CliError;

use super::models::{
    PolicyActionDescriptor, PolicyRunRequest, PolicyRunStep, PolicyRunTrigger, PolicyWorkflowRun,
};
use super::providers::{PolicyExecutionContext, PolicyProviderRegistry};
use super::repository::BeginRunOutcome;
#[cfg(test)]
use super::repository::PolicyRuntimeRepository;

pub struct PolicyRuntimeExecutor {
    storage: PolicyRunStorage,
    providers: PolicyProviderRegistry,
}

enum PolicyRunStorage {
    #[cfg(test)]
    LegacyFile(PolicyRuntimeRepository),
    Database(Arc<AsyncDaemonDb>),
}

impl PolicyRunStorage {
    async fn begin_run(
        &self,
        run: PolicyWorkflowRun,
        trigger: PolicyRunTrigger,
    ) -> Result<BeginRunOutcome, CliError> {
        match self {
            #[cfg(test)]
            Self::LegacyFile(repository) => repository.begin_run(run, trigger, Utc::now()),
            Self::Database(database) => {
                database
                    .begin_policy_workflow_run(run, trigger, Utc::now())
                    .await
            }
        }
    }

    async fn claim_waiting_run(
        &self,
        run_id: &str,
        trigger: PolicyRunTrigger,
    ) -> Result<Option<PolicyWorkflowRun>, CliError> {
        match self {
            #[cfg(test)]
            Self::LegacyFile(repository) => repository.claim_waiting_run(run_id, trigger),
            Self::Database(database) => database.claim_waiting_policy_run(run_id, trigger).await,
        }
    }

    async fn save(&self, run: &PolicyWorkflowRun) -> Result<(), CliError> {
        match self {
            #[cfg(test)]
            Self::LegacyFile(repository) => repository.save(run),
            Self::Database(database) => database.save_policy_workflow_run(run).await.map(|_| ()),
        }
    }
}

impl PolicyRuntimeExecutor {
    #[must_use]
    #[cfg(test)]
    pub fn new(repository: PolicyRuntimeRepository, providers: PolicyProviderRegistry) -> Self {
        Self {
            storage: PolicyRunStorage::LegacyFile(repository),
            providers,
        }
    }

    #[must_use]
    pub(crate) fn new_database(
        database: Arc<AsyncDaemonDb>,
        providers: PolicyProviderRegistry,
    ) -> Self {
        Self {
            storage: PolicyRunStorage::Database(database),
            providers,
        }
    }

    /// Begin a policy workflow run for the request's subject, executing its
    /// planned steps until completion or the first wait. A live run for the
    /// same workflow + subject is reused instead of started again.
    ///
    /// # Errors
    /// Returns `CliError` when the run cannot be persisted or a provider
    /// action fails; on failure the run is recorded as failed before the
    /// error is returned.
    pub async fn start(
        &self,
        trigger: PolicyRunTrigger,
        request: PolicyRunRequest,
    ) -> Result<PolicyWorkflowRun, CliError> {
        let PolicyRunRequest {
            workflow_id,
            subject,
            subject_fingerprint,
            steps,
        } = request;
        let run = PolicyWorkflowRun::new(
            &workflow_id,
            subject.clone(),
            subject_fingerprint,
            trigger,
            steps,
        );
        let ctx = PolicyExecutionContext {
            workflow_id,
            subject,
            trigger,
        };

        // Dedupe, supersede, and persist the new run atomically before any
        // action runs. A reused run is returned untouched; a freshly created
        // run is already durable (status Running), so a crash mid-run leaves a
        // recoverable record instead of silently losing executed side effects.
        match self.storage.begin_run(run, trigger).await? {
            BeginRunOutcome::Existing(existing) => Ok(existing),
            BeginRunOutcome::Created(run) => self.drive_created_run(run, &ctx, trigger).await,
        }
    }

    async fn drive_created_run(
        &self,
        mut run: PolicyWorkflowRun,
        ctx: &PolicyExecutionContext,
        trigger: PolicyRunTrigger,
    ) -> Result<PolicyWorkflowRun, CliError> {
        log_run_started(&run, trigger);
        let execution = self.execute_remaining_steps(&mut run, ctx).await;
        self.finish_execution(run, execution).await
    }

    /// Resume a waiting run identified by `run_id`, executing its remaining
    /// steps. Returns `None` when the run is missing or no longer waiting.
    ///
    /// # Errors
    /// Returns `CliError` when the run cannot be persisted or a provider
    /// action fails; on failure the run is recorded as failed before the
    /// error is returned.
    pub async fn resume(
        &self,
        run_id: &str,
        trigger: PolicyRunTrigger,
    ) -> Result<Option<PolicyWorkflowRun>, CliError> {
        // Atomically claim the waiting run (Waiting -> Running, persisted)
        // so a concurrent timer and event poll cannot both resume the same
        // run and execute its remaining actions (e.g. merge) twice.
        let Some(run) = self.storage.claim_waiting_run(run_id, trigger).await? else {
            return Ok(None);
        };
        self.drive_resumed_run(run, trigger).await.map(Some)
    }

    async fn drive_resumed_run(
        &self,
        mut run: PolicyWorkflowRun,
        trigger: PolicyRunTrigger,
    ) -> Result<PolicyWorkflowRun, CliError> {
        log_run_resumed(&run, trigger);
        let ctx = PolicyExecutionContext {
            workflow_id: run.workflow_id.clone(),
            subject: run.subject.clone(),
            trigger,
        };
        let execution = self.execute_remaining_steps(&mut run, &ctx).await;
        self.finish_execution(run, execution).await
    }

    async fn execute_remaining_steps(
        &self,
        run: &mut PolicyWorkflowRun,
        ctx: &PolicyExecutionContext,
    ) -> Result<(), CliError> {
        let remaining_steps = run
            .planned_steps
            .iter()
            .cloned()
            .enumerate()
            .skip(run.cursor.next_step_index)
            .collect::<Vec<_>>();

        for (index, step) in remaining_steps {
            if self.process_step(run, ctx, step, index).await?.is_break() {
                return Ok(());
            }
        }

        run.mark_completed();
        log_run_completed(run);
        Ok(())
    }

    /// Execute or enqueue a single planned step. Returns `Break` when the run
    /// has entered a wait and execution should pause, `Continue` otherwise.
    async fn process_step(
        &self,
        run: &mut PolicyWorkflowRun,
        ctx: &PolicyExecutionContext,
        step: PolicyRunStep,
        index: usize,
    ) -> Result<ControlFlow<()>, CliError> {
        match step {
            PolicyRunStep::Action(action) => {
                self.apply_action(run, ctx, &action, index).await?;
                Ok(ControlFlow::Continue(()))
            }
            PolicyRunStep::Wait(wait) => {
                run.mark_waiting(wait, index + 1);
                log_run_waiting(run);
                Ok(ControlFlow::Break(()))
            }
        }
    }

    async fn apply_action(
        &self,
        run: &mut PolicyWorkflowRun,
        ctx: &PolicyExecutionContext,
        action: &PolicyActionDescriptor,
        index: usize,
    ) -> Result<(), CliError> {
        let execution = self.providers.execute(action, ctx).await?;
        let action_key = execution.action_key.clone();
        run.record_action(execution.action_key, index + 1);
        // Persist after every action so the cursor advances durably and a
        // resume never replays an action that already ran.
        self.storage.save(run).await?;
        log_action_executed(run, &action_key);
        Ok(())
    }

    async fn finish_execution(
        &self,
        run: PolicyWorkflowRun,
        execution: Result<(), CliError>,
    ) -> Result<PolicyWorkflowRun, CliError> {
        match execution {
            Ok(()) => {
                self.storage.save(&run).await?;
                Ok(run)
            }
            Err(error) => self.record_failure(run, error).await,
        }
    }

    async fn record_failure(
        &self,
        mut run: PolicyWorkflowRun,
        error: CliError,
    ) -> Result<PolicyWorkflowRun, CliError> {
        run.mark_failed(error.to_string());
        self.storage.save(&run).await?;
        log_run_failed(&run, &error);
        Err(error)
    }
}

// The `tracing` event macros expand into the crate's structured-field
// machinery (a hidden enabled-check plus a static callsite match), which
// clippy's `cognitive_complexity` over-counts: a function whose entire body
// is a single `info!`/`warn!` already scores 8/7. These leaf loggers cannot
// be split any smaller, so the lint is a false positive here.
#[expect(
    clippy::cognitive_complexity,
    reason = "tracing event macro expansion is over-counted; body is a single log call"
)]
fn log_run_started(run: &PolicyWorkflowRun, trigger: PolicyRunTrigger) {
    info!(
        run_id = %run.run_id,
        workflow_id = %run.workflow_id,
        subject = %run.subject.key,
        trigger = ?trigger,
        "policy workflow run started"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing event macro expansion is over-counted; body is a single log call"
)]
fn log_run_resumed(run: &PolicyWorkflowRun, trigger: PolicyRunTrigger) {
    info!(
        run_id = %run.run_id,
        workflow_id = %run.workflow_id,
        trigger = ?trigger,
        "policy workflow run resumed"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing event macro expansion is over-counted; body is a single log call"
)]
fn log_run_waiting(run: &PolicyWorkflowRun) {
    info!(run_id = %run.run_id, "policy workflow run waiting");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing event macro expansion is over-counted; body is a single log call"
)]
fn log_run_completed(run: &PolicyWorkflowRun) {
    info!(run_id = %run.run_id, "policy workflow run completed");
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing event macro expansion is over-counted; body is a single log call"
)]
fn log_action_executed(run: &PolicyWorkflowRun, action_key: &str) {
    info!(
        run_id = %run.run_id,
        %action_key,
        "policy workflow action executed"
    );
}

#[expect(
    clippy::cognitive_complexity,
    reason = "tracing event macro expansion is over-counted; body is a single log call"
)]
fn log_run_failed(run: &PolicyWorkflowRun, error: &CliError) {
    warn!(run_id = %run.run_id, %error, "policy workflow run failed");
}
