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

    pub fn start(
        &self,
        trigger: PolicyRunTrigger,
        request: PolicyRunRequest,
    ) -> Result<PolicyWorkflowRun, CliError> {
        if let Some(mut existing) = self
            .repository
            .active_run(&request.workflow_id, &request.subject.key)?
        {
            if matches!(trigger, PolicyRunTrigger::Manual) {
                existing.nudge_manually();
                self.repository.save(&existing)?;
            }
            return Ok(existing);
        }

        let mut run = PolicyWorkflowRun::new(&request.workflow_id, request.subject.clone(), trigger);
        let ctx = PolicyExecutionContext {
            workflow_id: request.workflow_id,
            subject: request.subject,
            trigger,
        };

        for (index, step) in request.steps.iter().enumerate() {
            match step {
                PolicyRunStep::Action(action) => {
                    let execution = self.providers.execute(action, &ctx)?;
                    run.record_action(execution.action_key, index + 1);
                }
                PolicyRunStep::Wait(wait) => {
                    run.mark_waiting(wait.clone(), index + 1);
                    self.repository.save(&run)?;
                    return Ok(run);
                }
            }
        }

        run.mark_completed();
        self.repository.save(&run)?;
        Ok(run)
    }
}
