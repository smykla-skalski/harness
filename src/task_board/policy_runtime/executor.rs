use chrono::Utc;
use tracing::{info, warn};

use crate::errors::CliError;

use super::models::{PolicyRunRequest, PolicyRunStep, PolicyRunTrigger, PolicyWorkflowRun};
use super::providers::{PolicyExecutionContext, PolicyProviderRegistry};
use super::repository::{BeginRunOutcome, PolicyRuntimeRepository};

pub struct PolicyRuntimeExecutor {
    repository: PolicyRuntimeRepository,
    providers: PolicyProviderRegistry,
}

impl PolicyRuntimeExecutor {
    #[must_use]
    pub fn new(repository: PolicyRuntimeRepository, providers: PolicyProviderRegistry) -> Self {
        Self {
            repository,
            providers,
        }
    }

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
        match self.repository.begin_run(run, trigger, Utc::now())? {
            BeginRunOutcome::Existing(existing) => Ok(existing),
            BeginRunOutcome::Created(mut run) => {
                info!(
                    run_id = %run.run_id,
                    workflow_id = %run.workflow_id,
                    subject = %run.subject.key,
                    trigger = ?trigger,
                    "policy workflow run started"
                );
                let execution = self.execute_remaining_steps(&mut run, &ctx).await;
                self.finish_execution(run, execution)
            }
        }
    }

    pub async fn resume(
        &self,
        run_id: &str,
        trigger: PolicyRunTrigger,
    ) -> Result<Option<PolicyWorkflowRun>, CliError> {
        // Atomically claim the waiting run (Waiting -> Running, persisted)
        // so a concurrent timer and event poll cannot both resume the same
        // run and execute its remaining actions (e.g. merge) twice.
        let Some(mut run) = self.repository.claim_waiting_run(run_id, trigger)? else {
            return Ok(None);
        };
        info!(
            run_id = %run.run_id,
            workflow_id = %run.workflow_id,
            trigger = ?trigger,
            "policy workflow run resumed"
        );
        let ctx = PolicyExecutionContext {
            workflow_id: run.workflow_id.clone(),
            subject: run.subject.clone(),
            trigger,
        };
        let execution = self.execute_remaining_steps(&mut run, &ctx).await;
        self.finish_execution(run, execution).map(Some)
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
            match step {
                PolicyRunStep::Action(action) => {
                    let execution = self.providers.execute(&action, ctx).await?;
                    let action_key = execution.action_key.clone();
                    run.record_action(execution.action_key, index + 1);
                    // Persist after every action so the cursor advances durably
                    // and a resume never replays an action that already ran.
                    self.repository.save(run)?;
                    info!(
                        run_id = %run.run_id,
                        %action_key,
                        "policy workflow action executed"
                    );
                }
                PolicyRunStep::Wait(wait) => {
                    run.mark_waiting(wait, index + 1);
                    info!(run_id = %run.run_id, "policy workflow run waiting");
                    return Ok(());
                }
            }
        }

        run.mark_completed();
        info!(run_id = %run.run_id, "policy workflow run completed");
        Ok(())
    }

    fn finish_execution(
        &self,
        mut run: PolicyWorkflowRun,
        execution: Result<(), CliError>,
    ) -> Result<PolicyWorkflowRun, CliError> {
        match execution {
            Ok(()) => {
                self.repository.save(&run)?;
                Ok(run)
            }
            Err(error) => {
                run.mark_failed(error.to_string());
                self.repository.save(&run)?;
                warn!(run_id = %run.run_id, %error, "policy workflow run failed");
                Err(error)
            }
        }
    }
}
