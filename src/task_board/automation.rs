//! Shared contracts for durable Task Board automation.

mod admission;
mod interfaces;
mod launch_capability;
mod policy_compiler;
mod policy_compiler_windows;
mod remote;
mod settings;
mod status;
mod wake;
mod workflow;

pub use admission::*;
pub use interfaces::*;
pub use launch_capability::*;
pub use policy_compiler::*;
pub use remote::*;
pub use settings::*;
pub use status::*;
pub use workflow::*;

pub(crate) use wake::*;

#[cfg(test)]
mod admission_tests;
#[cfg(test)]
mod launch_capability_tests;
#[cfg(test)]
mod policy_compiler_tests;
