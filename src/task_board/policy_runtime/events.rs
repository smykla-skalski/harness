use crate::task_board::policy_graph::PolicyWaitCondition;

use super::models::{PolicyRunStatus, PolicyWorkflowEvent, PolicyWorkflowRun};

#[must_use]
pub fn wait_matches_event(wait: &PolicyWaitCondition, event: &PolicyWorkflowEvent) -> bool {
    match wait {
        PolicyWaitCondition::Event { event_key } => event_key == &event.event_key,
        PolicyWaitCondition::Timer { .. } => false,
    }
}

#[must_use]
pub fn run_matches_event(run: &PolicyWorkflowRun, event: &PolicyWorkflowEvent) -> bool {
    run.status == PolicyRunStatus::Waiting
        && run.subject.key == event.subject_key
        && run
            .waiting_on
            .as_ref()
            .is_some_and(|wait| wait_matches_event(wait, event))
}
