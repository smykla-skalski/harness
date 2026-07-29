//! Shared contracts for durable Task Board automation.

// `TaskBoardWorkflowKind` moved to `harness-task-board` with `TaskBoardItem`,
// the struct that embeds it (see `workflow.rs`'s own import). This module's
// `#[cfg(test)]` children reach it through `super::*`, which only sees this
// module's own (re-)exports, not a sibling file's private import, so it needs
// restating here even though nothing in this file's own non-test code uses it
// directly.
#[cfg(test)]
use crate::TaskBoardWorkflowKind;

mod admission;
mod attempt_result_validation;
mod dependency_triage;
mod interfaces;
mod launch_capability;
mod orchestrator_workflow;
mod planning_approval;
mod policy_compiler;
mod policy_compiler_windows;
mod read_only_workflow;
mod remote;
mod remote_local_config;
mod report_only_review;
mod retry;
mod review_report;
mod reviewer_resolution;
mod settings;
mod status;
mod wake;
mod workflow;
mod workflow_execution;
mod workflow_execution_authority_validation;
mod workflow_execution_remote_handoff_validation;
mod workflow_execution_target_validation;
mod workflow_execution_validation;
mod workflow_execution_write_validation;
mod workflow_transitions;

pub use admission::*;
// Widened from `pub(crate)` now that automation is its own crate: the daemon's
// task-board scheduler reaches these across the crate boundary through the
// root crate's `pub use harness_task_board::*;` facade, and `pub(crate)` no
// longer reaches that far once the two crates are separate compilation units.
pub use attempt_result_validation::*;
pub use dependency_triage::*;
pub use interfaces::*;
pub use launch_capability::*;
pub use orchestrator_workflow::*;
pub use planning_approval::*;
pub use policy_compiler::*;
pub use read_only_workflow::*;
pub use remote::*;
pub use remote_local_config::*;
pub use report_only_review::*;
pub use retry::*;
pub use review_report::*;
pub use reviewer_resolution::*;
pub use settings::*;
pub use status::*;
pub use workflow::*;
pub use workflow_execution::*;
pub use workflow_execution_remote_handoff_validation::*;
pub use workflow_execution_target_validation::*;
pub use workflow_execution_validation::*;
pub use workflow_transitions::*;

pub use wake::*;

#[cfg(test)]
mod admission_tests;
#[cfg(test)]
mod launch_capability_tests;
#[cfg(test)]
mod planning_approval_provenance_tests;
#[cfg(test)]
mod planning_approval_tests;
#[cfg(test)]
mod policy_compiler_tests;
#[cfg(test)]
mod remote_config_tests;
#[cfg(test)]
mod remote_observation_tests;
#[cfg(test)]
mod reviewer_resolution_tests;
#[cfg(test)]
mod workflow_execution_target_validation_tests;
#[cfg(test)]
mod workflow_transition_tests;
#[cfg(test)]
mod workflow_write_validation_tests;
