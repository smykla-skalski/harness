pub(crate) mod adapters;
pub(crate) mod application;
mod catalog;
mod effects;
pub mod protocol;
pub(crate) mod registry;
mod runtime;
pub(crate) mod session;
#[cfg(test)]
mod tests;
mod transport;

pub use self::adapters::HookAgent;
pub use self::application::GuardContext;
pub use self::effects::HookOutcome;
pub use self::protocol::{context, hook_result, output, payloads, result};
pub use self::session::{PreCompactHookInput, SessionStartHookInput, SessionStartHookOutput};
pub use self::transport::{AuditTurnArgs, HookArgs, HookCommand, HookType};

pub use self::runtime::run_hook_command;
