use crate::errors::CliError;
use crate::hooks::context::{GuardContext, NormalizedHookContext};
use crate::hooks::effects::{HookOutcome, apply_effects};
use crate::hooks::result::NormalizedHookResult;

use super::HookType;

/// A composable guard in the hook engine chain-of-responsibility.
pub trait Guard: Send + Sync {
    fn check(&self, ctx: &GuardContext) -> Option<NormalizedHookResult>;
}

/// Ordered collection of guards that stops at the first denial/warning.
pub struct GuardChain {
    guards: Vec<Box<dyn Guard>>,
}

impl GuardChain {
    #[must_use]
    pub fn new(guards: Vec<Box<dyn Guard>>) -> Self {
        Self { guards }
    }

    #[must_use]
    pub fn evaluate(&self, ctx: &GuardContext) -> NormalizedHookResult {
        for guard in &self.guards {
            if let Some(result) = guard.check(ctx) {
                return result;
            }
        }
        NormalizedHookResult::allow()
    }
}

/// Trait-based hook registration used by the engine.
pub trait Hook: Send + Sync {
    fn name(&self) -> &str;
    fn hook_type(&self) -> HookType;
    fn execute(&self, ctx: &GuardContext) -> Result<HookOutcome, CliError>;
}

/// Agent-agnostic hook execution engine.
pub struct HookEngine;

impl HookEngine {
    #[must_use]
    pub fn new() -> Self {
        Self
    }

    /// Execute one registered hook against a normalized input.
    ///
    /// # Errors
    /// Returns `CliError` when hook execution or effect application fails.
    pub fn execute(
        &self,
        hook: &dyn Hook,
        normalized: NormalizedHookContext,
    ) -> Result<NormalizedHookResult, CliError> {
        let guard_context = GuardContext::from_normalized(normalized);
        let mut outcome = hook.execute(&guard_context)?;
        apply_effects(&guard_context, &mut outcome.result, &outcome.effects)?;
        Ok(outcome.result)
    }
}
