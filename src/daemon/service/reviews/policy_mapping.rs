use crate::errors::{CliError, CliErrorKind};
use crate::reviews::{
    ReviewsPolicyPreviewStep, ReviewsPolicyRunResponse, ReviewsPolicyRunStatus,
    ReviewsPolicyRunStep, ReviewsPolicyStepType, ReviewsPolicySubject, ReviewsPolicyTrigger,
    ReviewsPolicyWait,
};
use crate::task_board::policy_graph::PolicyWaitCondition;
use crate::task_board::policy_runtime::models::{
    PolicyRunStatus, PolicyRunStep, PolicyRunTrigger, PolicyWorkflowRun, PolicyWorkflowStepType,
};

pub(crate) fn preview_step(step: &PolicyRunStep) -> ReviewsPolicyPreviewStep {
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

pub(crate) fn map_run_response(
    run: &PolicyWorkflowRun,
) -> Result<ReviewsPolicyRunResponse, CliError> {
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

pub(crate) fn runtime_trigger_from_reviews(trigger: ReviewsPolicyTrigger) -> PolicyRunTrigger {
    match trigger {
        ReviewsPolicyTrigger::Background => PolicyRunTrigger::Background,
        ReviewsPolicyTrigger::Event => PolicyRunTrigger::Event,
        ReviewsPolicyTrigger::Manual => PolicyRunTrigger::Manual,
        ReviewsPolicyTrigger::ManualNudge => PolicyRunTrigger::ManualNudge,
        ReviewsPolicyTrigger::Timer => PolicyRunTrigger::Timer,
    }
}

fn reviews_step_type_from_runtime(step_type: PolicyWorkflowStepType) -> ReviewsPolicyStepType {
    match step_type {
        PolicyWorkflowStepType::Action => ReviewsPolicyStepType::Action,
        PolicyWorkflowStepType::Wait => ReviewsPolicyStepType::Wait,
    }
}
