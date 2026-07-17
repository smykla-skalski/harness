//! Shared contracts for durable Task Board automation.

mod interfaces;
mod remote;
mod settings;
mod status;
mod wake;
mod workflow;

pub use interfaces::*;
pub use remote::*;
pub use settings::*;
pub use status::*;
pub use workflow::*;

pub(crate) use wake::*;
