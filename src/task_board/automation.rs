//! Shared contracts for durable Task Board automation.

mod admission;
mod interfaces;
mod launch_capability;
mod policy_compiler;
mod policy_compiler_windows;
mod read_only_workflow;
mod remote;
mod retry;
mod reviewer_resolution;
mod settings;
mod status;
mod wake;
mod workflow;
mod workflow_execution;
mod workflow_execution_validation;
mod workflow_transitions;

pub use admission::*;
pub use interfaces::*;
pub use launch_capability::*;
pub use policy_compiler::*;
pub use read_only_workflow::*;
pub use remote::*;
pub use retry::*;
pub use reviewer_resolution::*;
pub use settings::*;
pub use status::*;
pub use workflow::*;
pub use workflow_execution::*;
pub use workflow_execution_validation::*;
pub use workflow_transitions::*;

pub(crate) use wake::*;

#[cfg(test)]
mod admission_tests;
#[cfg(test)]
mod launch_capability_tests;
#[cfg(test)]
mod policy_compiler_tests;
#[cfg(test)]
mod reviewer_resolution_tests;
#[cfg(test)]
mod workflow_transition_tests;
