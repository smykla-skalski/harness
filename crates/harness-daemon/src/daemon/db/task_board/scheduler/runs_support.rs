use super::super::control::TaskBoardAutomationControlRecord;
use super::{TaskBoardAutomationRunFence, TaskBoardAutomationRunLease, TaskBoardRunAcquireRequest};
use crate::daemon::db::{CliError, db_error};
use crate::task_board::{
    TaskBoardAutomationAdmissionState, TaskBoardAutomationDesiredMode,
    TaskBoardAutomationRunOutcome, TaskBoardAutomationRunTrigger,
};

pub(super) fn run_lease(
    request: &TaskBoardRunAcquireRequest,
    control: &TaskBoardAutomationControlRecord,
    lease_epoch: u64,
) -> TaskBoardAutomationRunLease {
    TaskBoardAutomationRunLease {
        run_id: request.run_id.clone(),
        trigger: request.trigger,
        lease_owner: request.lease_owner.clone(),
        lease_epoch,
        stop_generation: control.stop_generation,
        started_at: request.now.to_rfc3339(),
    }
}

pub(super) fn run_fence(
    lease: &TaskBoardAutomationRunLease,
    control: &TaskBoardAutomationControlRecord,
    state: &str,
) -> TaskBoardAutomationRunFence {
    if state == "cancelling"
        || control.stop_generation != lease.stop_generation
        || !admission_is_open(lease.trigger, control)
    {
        TaskBoardAutomationRunFence::Draining
    } else {
        TaskBoardAutomationRunFence::Active
    }
}

pub(super) fn final_outcome(
    lease: &TaskBoardAutomationRunLease,
    control: &TaskBoardAutomationControlRecord,
    state: &str,
    requested: TaskBoardAutomationRunOutcome,
) -> TaskBoardAutomationRunOutcome {
    if state == "cancelling" || control.stop_generation != lease.stop_generation {
        TaskBoardAutomationRunOutcome::Cancelled
    } else {
        requested
    }
}

pub(super) fn trigger_is_enabled(
    trigger: TaskBoardAutomationRunTrigger,
    control: &TaskBoardAutomationControlRecord,
) -> bool {
    match trigger {
        TaskBoardAutomationRunTrigger::Manual => {
            control.admission_state != TaskBoardAutomationAdmissionState::Draining
        }
        TaskBoardAutomationRunTrigger::Recovery
        | TaskBoardAutomationRunTrigger::Scheduled
        | TaskBoardAutomationRunTrigger::Event => {
            control.desired_mode == TaskBoardAutomationDesiredMode::Continuous
                && control.admission_state == TaskBoardAutomationAdmissionState::Accepting
        }
    }
}

fn admission_is_open(
    trigger: TaskBoardAutomationRunTrigger,
    control: &TaskBoardAutomationControlRecord,
) -> bool {
    trigger == TaskBoardAutomationRunTrigger::Manual
        || control.admission_state == TaskBoardAutomationAdmissionState::Accepting
}

pub(in super::super) const fn run_trigger_label(
    trigger: TaskBoardAutomationRunTrigger,
) -> &'static str {
    match trigger {
        TaskBoardAutomationRunTrigger::Scheduled => "scheduled",
        TaskBoardAutomationRunTrigger::Event => "event",
        TaskBoardAutomationRunTrigger::Manual => "manual",
        TaskBoardAutomationRunTrigger::Recovery => "recovery",
    }
}

pub(in super::super) const fn run_outcome_label(
    outcome: TaskBoardAutomationRunOutcome,
) -> &'static str {
    match outcome {
        TaskBoardAutomationRunOutcome::Completed => "completed",
        TaskBoardAutomationRunOutcome::Noop => "noop",
        TaskBoardAutomationRunOutcome::Partial => "partial",
        TaskBoardAutomationRunOutcome::Failed => "failed",
        TaskBoardAutomationRunOutcome::Cancelled => "cancelled",
    }
}

pub(super) fn ensure_single_run_changed(changed: u64, run_id: &str) -> Result<(), CliError> {
    if changed == 1 {
        Ok(())
    } else {
        Err(lost_lease(run_id))
    }
}

pub(super) fn to_db_integer(value: u64) -> i64 {
    i64::try_from(value).unwrap_or(i64::MAX)
}

pub(super) fn expired_lease(run_id: &str) -> CliError {
    db_error(format!(
        "task board automation run '{run_id}' lease expired"
    ))
}

pub(super) fn lost_lease(run_id: &str) -> CliError {
    db_error(format!(
        "task board automation run '{run_id}' lost its coordinator lease"
    ))
}
