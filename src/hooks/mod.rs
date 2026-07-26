pub(crate) mod adapters;
pub(crate) mod application;
mod catalog;
#[cfg(test)]
pub(crate) mod debug;
mod effects;
pub mod guard_bash;
pub mod guard_question;
pub mod guard_write;
pub mod protocol;
pub(crate) mod registry;
pub(crate) mod runner_policy;
mod runtime;
pub(crate) mod session;
#[cfg(test)]
mod tests;
mod tool_dispatch;
pub mod tool_guard;
pub mod tool_result;
mod transport;
pub mod verify_question;
pub mod verify_write;
mod write_surface;

pub use self::adapters::HookAgent;
pub use self::application::GuardContext;
pub use self::effects::{HookEffect, HookOutcome};
pub use self::protocol::{context, hook_result, output, payloads, result};
pub use self::session::{PreCompactHookInput, SessionStartHookInput, SessionStartHookOutput};
pub use self::transport::{AuditTurnArgs, HookArgs, HookCommand, HookType};

pub use self::runtime::run_hook_command;
pub(crate) use self::runtime::{dispatch_by_skill, dispatch_outcome_by_skill};
pub(crate) use self::write_surface::normalize_path;
