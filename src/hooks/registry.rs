use crate::hooks::application::GuardContext;
use crate::hooks::effects::HookOutcome;
use crate::hooks::protocol::context::NormalizedHookContext;
use crate::hooks::protocol::result::NormalizedHookResult;
use harness_kernel::errors::CliError;

use super::HookType;

/// Trait-based hook registration used by the engine.
pub trait Hook: Send + Sync {
    fn name(&self) -> &str;
    fn hook_type(&self) -> HookType;
    /// Run the hook logic against a guard context.
    ///
    /// # Errors
    /// Returns `CliError` when hook execution fails.
    fn execute(&self, ctx: &GuardContext) -> Result<HookOutcome, CliError>;
}

/// Agent-agnostic hook execution engine.
pub struct HookEngine;

impl Default for HookEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl HookEngine {
    #[must_use]
    pub fn new() -> Self {
        Self
    }

    /// Execute one registered hook against a normalized input.
    ///
    /// # Errors
    /// Returns `CliError` when hook execution fails.
    pub fn execute(
        hook: &dyn Hook,
        normalized: NormalizedHookContext,
    ) -> Result<NormalizedHookResult, CliError> {
        let guard_context = GuardContext::from_normalized(normalized);
        let outcome = hook.execute(&guard_context)?;
        Ok(outcome.normalized_result())
    }
}
