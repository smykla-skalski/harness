use crate::task_board::policy_graph::PolicyWaitCondition;

use super::models::{PolicyRunStatus, PolicyWorkflowRun};

#[must_use]
pub fn is_timer_waiting(run: &PolicyWorkflowRun) -> bool {
    run.status == PolicyRunStatus::Waiting
        && matches!(run.waiting_on, Some(PolicyWaitCondition::Timer { .. }))
}
