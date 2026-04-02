use crate::errors::CliError;
use crate::hooks::application::GuardContext as HookContext;

use super::effects::HookOutcome;

/// Execute the unified post-tool-failure hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookOutcome, CliError> {
    let outcome = super::enrich_failure::execute(ctx)?;
    let audit = super::audit::execute(ctx)?;

    Ok(outcome.append_non_decision_effects(audit.effects()))
}
