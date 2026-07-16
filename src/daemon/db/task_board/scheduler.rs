//! Durable scheduler state for Task Board automation.

mod audit;
mod control;
mod recovery;
mod runs;
mod stages;

#[cfg(test)]
mod control_tests;
#[cfg(test)]
mod recovery_tests;
#[cfg(test)]
mod runs_tests;
#[cfg(test)]
mod stages_tests;
#[cfg(test)]
mod test_support;

pub(crate) use control::TaskBoardAutomationControlRecord;
pub(crate) use runs::{
    TaskBoardAutomationRunAdmission, TaskBoardAutomationRunFence, TaskBoardAutomationRunLease,
    TaskBoardRunAcquireRequest,
};
pub(crate) use stages::TaskBoardAutomationRunStage;
