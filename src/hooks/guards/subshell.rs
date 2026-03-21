use crate::errors::HookMessage;
use crate::hooks::application::GuardContext;
use crate::hooks::guard_bash::predicates::has_denied_subshell_binary;
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::hooks::registry::Guard;

use super::parsed_parts;

/// Denies commands that hide blocked binaries inside subshell substitution
/// (`$(...)` or backtick) forms.
pub struct SubshellGuard;

impl Guard for SubshellGuard {
    fn check(&self, ctx: &GuardContext) -> Option<NormalizedHookResult> {
        let (_, words, _) = parsed_parts(ctx)?;
        if has_denied_subshell_binary(ctx.command_text(), words) {
            Some(NormalizedHookResult::from_hook_result(
                HookMessage::SubshellSmuggling.into_result(),
            ))
        } else {
            None
        }
    }
}

#[cfg(test)]
#[path = "subshell/tests.rs"]
mod tests;
