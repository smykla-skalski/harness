use std::fmt;
use std::path::Path;

mod cli_error;
mod cli_kind;
mod common;
mod create_observe;
mod hook_message;
mod run_setup;
#[cfg(test)]
mod tests;
mod workflow;

pub use cli_error::{CliError, render_error};
pub use hook_message::HookMessage;

use self::common::CommonError;
use self::create_observe::CreateObserveError;
use self::run_setup::RunSetupError;
use self::workflow::WorkflowError;

/// Build an IO-category `CliErrorKind` from an operation name, path, and cause.
///
/// Formats the message as `"{operation} {path}: {cause}"` and wraps it in
/// `CliErrorKind::io`. Use this instead of manual string formatting for
/// filesystem errors that reference a path.
#[must_use]
pub fn io_for(operation: &str, path: &Path, cause: &dyn fmt::Display) -> CliErrorKind {
    CliErrorKind::io(format!("{operation} {}: {cause}", path.display()))
}

/// Public wrapper around domain-specific CLI errors.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum CliErrorKind {
    #[error(transparent)]
    Common(CommonError),
    #[error(transparent)]
    RunSetup(RunSetupError),
    #[error(transparent)]
    CreateObserve(CreateObserveError),
    #[error(transparent)]
    Workflow(WorkflowError),
}
