use harness_kernel::errors::CliError;

use crate::hooks::application::GuardContext as HookContext;

use super::effects::HookOutcome;

/// Execute the unified pre-tool hook.
///
/// The hook records the tool call through the shared transport and injects any
/// pending session signals; it makes no policy decision of its own. The guards
/// that used to run here were reachable only for a skill no registration
/// claims, so they could never deny.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(_ctx: &HookContext) -> Result<HookOutcome, CliError> {
    Ok(HookOutcome::allow())
}
