#![deny(unsafe_code)]

// `adapters` is public rather than crate-internal: `harness_hooks::adapters`
// is a real cross-crate path for `adapter_for`/`HookRegistration` (root's
// `src/setup/wrapper` and `harness-hook`'s own agent-service shim both reach
// it by that full path, not just the `HookAgent` re-export below).
pub mod adapters;
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
pub use self::session::SessionStartHookOutput;
pub use self::transport::{AuditTurnArgs, HookCommand, HookType};

pub use self::runtime::run_hook_command;
