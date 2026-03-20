use std::fmt;
use std::path::Path;

mod authoring_observe;
mod cli_error;
mod cli_kind;
mod common;
mod hook_message;
mod run_setup;
#[cfg(test)]
mod tests;
mod workflow;

pub use cli_error::{CliError, render_error};
pub use hook_message::HookMessage;

use self::authoring_observe::AuthoringObserveError;
use self::common::CommonError;
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

macro_rules! define_domain_error_enum {
    (
        $name:ident {
            $(
                $variant:ident $({ $($field:ident : $type:ty),* $(,)? })?
                => {
                    code: $code:literal,
                    msg: $msg:literal
                    $(, exit: $exit:expr)?
                }
            ),* $(,)?
        }
    ) => {
        #[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
        #[non_exhaustive]
        pub enum $name {
            $(
                #[error($msg)]
                $variant $({ $($field: $type),* })?,
            )*
        }

        impl $name {
            #[must_use]
            pub fn code(&self) -> &'static str {
                match self {
                    $(Self::$variant { .. } => $code,)*
                }
            }

            #[must_use]
            pub fn exit_code(&self) -> i32 {
                match self {
                    $(Self::$variant { .. } => define_domain_error_enum!(@exit $($exit)?),)*
                }
            }
        }
    };

    (@exit) => { 5 };
    (@exit $exit:expr) => { $exit };
}

pub(crate) use define_domain_error_enum;

macro_rules! domain_constructor {
    ($fn_name:ident, $variant:ident, $($field:ident),+) => {
        pub fn $fn_name($($field: impl Into<Cow<'static, str>>),+) -> Self {
            Self::$variant { $($field: $field.into()),+ }
        }
    };
}

pub(crate) use domain_constructor;

/// Public wrapper around domain-specific CLI errors.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[non_exhaustive]
pub enum CliErrorKind {
    #[error(transparent)]
    Common(CommonError),
    #[error(transparent)]
    RunSetup(RunSetupError),
    #[error(transparent)]
    AuthoringObserve(AuthoringObserveError),
    #[error(transparent)]
    Workflow(WorkflowError),
}
