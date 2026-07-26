use harness_kernel::errors::CliError;

use crate::hooks::application::GuardContext as HookContext;

use super::effects::HookOutcome;

/// Execute the unified post-tool hook.
///
/// The hook records the tool result through the shared transport; it makes no
/// policy decision of its own. The verify handlers that used to run here were
/// reachable only for a skill no registration claims, so they could never deny.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(_ctx: &HookContext) -> Result<HookOutcome, CliError> {
    Ok(HookOutcome::allow())
}
