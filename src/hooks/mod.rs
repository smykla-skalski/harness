pub(crate) mod adapters;
pub(crate) mod application;
pub mod audit;
mod catalog;
pub mod context_agent;
#[cfg(test)]
pub(crate) mod debug;
mod effects;
pub mod enrich_failure;
pub mod guard_bash;
pub mod guard_question;
pub mod guard_stop;
pub mod guard_write;
#[cfg(test)]
pub(crate) mod guards;
pub mod protocol;
pub(crate) mod registry;
pub(crate) mod runner_policy;
mod runtime;
pub(crate) mod session;
#[cfg(test)]
mod tests;
mod tool_dispatch;
pub mod tool_failure;
pub mod tool_guard;
pub mod tool_result;
mod transport;
pub mod validate_agent;
pub mod verify_bash;
pub mod verify_question;
pub mod verify_write;
mod write_surface;

pub use self::application::GuardContext;
pub use self::effects::{HookEffect, HookOutcome};
pub use self::protocol::{context, hook_result, output, payloads, result};
pub use self::session::{PreCompactHookInput, SessionStartHookInput, SessionStartHookOutput};
pub use self::transport::{AuditTurnArgs, HookArgs, HookCommand, HookType};

pub use self::runtime::run_hook_command;
pub(crate) use self::runtime::{dispatch_by_skill, dispatch_outcome_by_skill};
pub(crate) use self::write_surface::{
    control_file_hint, is_command_owned_run_file, normalize_path,
};
