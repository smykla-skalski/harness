use crate::errors::CliError;

use super::models::{PolicyRunRequest, PolicyRunStep, PolicyRunTrigger, PolicyWorkflowRun};
use super::providers::{PolicyExecutionContext, PolicyProviderRegistry};
use super::repository::PolicyRuntimeRepository;

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
        let active_runs = self
            .repository
            .active_runs_for_subject(&workflow_id, &subject.key)?;

        if let Some(fingerprint) = subject_fingerprint.as_deref() {
            if let Some(mut existing) = active_runs
                .iter()
                .find(|run| run.subject_fingerprint.as_deref() == Some(fingerprint))
                .cloned()
            {
                if matches!(trigger, PolicyRunTrigger::Manual) {
                    existing.nudge_manually();
                    self.repository.save(&existing)?;
                }
                return Ok(existing);
            }
            for mut stale in active_runs
                .into_iter()
                .filter(|run| run.subject_fingerprint.as_deref() != Some(fingerprint))
            {
                stale.mark_cancelled("superseded by newer workflow subject state");
                self.repository.save(&stale)?;
            }
        } else if let Some(mut existing) = active_runs.into_iter().next() {
            if matches!(trigger, PolicyRunTrigger::Manual) {
                existing.nudge_manually();
                self.repository.save(&existing)?;
            }
            return Ok(existing);
        }

        let mut run = PolicyWorkflowRun::new(
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

        let execution = self.execute_remaining_steps(&mut run, &ctx).await;
        self.finish_execution(run, execution)
    }

    pub async fn resume(
        &self,
        run_id: &str,
        trigger: PolicyRunTrigger,
    ) -> Result<Option<PolicyWorkflowRun>, CliError> {
        let Some(mut run) = self.repository.run_by_id(run_id)? else {
            return Ok(None);
        };
        run.mark_running(trigger);
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
                    run.record_action(execution.action_key, index + 1);
                }
                PolicyRunStep::Wait(wait) => {
                    run.mark_waiting(wait, index + 1);
                    return Ok(());
                }
            }
        }

        run.mark_completed();
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
                Err(error)
            }
        }
    }
}
