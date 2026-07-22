//! Shared contracts for durable Task Board automation.

mod admission;
mod attempt_result_validation;
mod interfaces;
mod launch_capability;
mod planning_approval;
mod policy_compiler;
mod policy_compiler_windows;
mod read_only_workflow;
mod remote;
mod remote_local_config;
mod retry;
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
pub(crate) use attempt_result_validation::*;
pub use interfaces::*;
pub use launch_capability::*;
pub use planning_approval::*;
pub use policy_compiler::*;
pub use read_only_workflow::*;
pub use remote::*;
pub use remote_local_config::*;
pub use retry::*;
pub use reviewer_resolution::*;
pub use settings::*;
pub use status::*;
pub use workflow::*;
pub use workflow_execution::*;
pub(crate) use workflow_execution_remote_handoff_validation::*;
pub use workflow_execution_target_validation::*;
pub use workflow_execution_validation::*;
pub use workflow_transitions::*;

pub(crate) use wake::*;

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
