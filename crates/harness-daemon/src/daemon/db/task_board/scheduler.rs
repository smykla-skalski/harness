//! Durable scheduler state for Task Board automation.

mod audit;
mod control;
mod history;
mod metrics;
mod recovery;
mod runs;
mod stages;
mod status;
mod wake;

#[cfg(test)]
mod control_tests;
#[cfg(test)]
mod history_tests;
#[cfg(test)]
mod metrics_tests;
#[cfg(test)]
mod recovery_tests;
#[cfg(test)]
mod runs_tests;
#[cfg(test)]
mod stages_tests;
#[cfg(test)]
mod status_atomicity_tests;
#[cfg(test)]
mod status_tests;
#[cfg(test)]
mod test_support;
#[cfg(test)]
mod wake_tests;

pub(crate) use crate::task_board::TaskBoardAutomationRunStage;
pub(crate) use control::TaskBoardAutomationControlRecord;
pub(crate) use runs::{
    TaskBoardAutomationRunAdmission, TaskBoardAutomationRunFence, TaskBoardAutomationRunLease,
    TaskBoardRunAcquireRequest,
};
