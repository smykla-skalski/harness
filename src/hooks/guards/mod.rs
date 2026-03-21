mod admin_endpoint;
mod denied_binary;
mod make_target;
mod run_phase;
mod structural;
mod subshell;

pub use admin_endpoint::AdminEndpointGuard;
pub use denied_binary::DeniedBinaryGuard;
pub use make_target::MakeTargetGuard;
pub use run_phase::RunPhaseGuard;
pub use structural::StructuralGuard;
pub use subshell::SubshellGuard;

use crate::hooks::application::GuardContext;
use crate::hooks::registry::GuardChain;
use crate::kernel::command_intent::ParsedCommand;

/// Extract parsed command parts, returning `None` when the command is empty
/// or missing. Parse errors are treated as allow-through so the caller's
/// top-level handler can surface the error with the right hook message.
fn parsed_parts(ctx: &GuardContext) -> Option<(&ParsedCommand, &[String], &[String])> {
    let command = ctx.parsed_command().ok().flatten()?;
    let words = command.words();
    if words.is_empty() {
        return None;
    }
    Some((command, words, command.heads()))
}

/// Build the standard guard chain for suite:run bash commands.
#[must_use]
pub fn runner_bash_chain() -> GuardChain {
    GuardChain::new(vec![
        Box::new(RunPhaseGuard),
        Box::new(SubshellGuard),
        Box::new(DeniedBinaryGuard::runner()),
        Box::new(MakeTargetGuard),
        Box::new(StructuralGuard),
        Box::new(AdminEndpointGuard),
    ])
}

/// Build the standard guard chain for suite:new bash commands.
#[must_use]
pub fn author_bash_chain() -> GuardChain {
    GuardChain::new(vec![
        Box::new(SubshellGuard),
        Box::new(DeniedBinaryGuard::author()),
        Box::new(AdminEndpointGuard),
    ])
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
