use crate::hooks::application::GuardContext as HookContext;
use harness_kernel::errors::CliError;

use super::effects::HookOutcome;

/// Execute the unified post-tool-failure hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookOutcome, CliError> {
    super::audit::execute(ctx)
}
