use harness_kernel::errors::CliError;

use super::application::GuardContext;
use super::registry::Hook;
use super::{HookOutcome, HookType};

type HookFn = fn(&GuardContext) -> Result<HookOutcome, CliError>;

struct StaticHook {
    name: &'static str,
    hook_type: HookType,
    run: HookFn,
}

impl StaticHook {
    const fn effect(name: &'static str, hook_type: HookType, run: HookFn) -> Self {
        Self {
            name,
            hook_type,
            run,
        }
    }
}

impl Hook for StaticHook {
    fn name(&self) -> &str {
        self.name
    }

    fn hook_type(&self) -> HookType {
        self.hook_type
    }

    fn execute(&self, ctx: &GuardContext) -> Result<HookOutcome, CliError> {
        (self.run)(ctx)
    }
}

/// Shared body for both tool-lifecycle hooks: neither holds any policy.
///
/// The statics below are the dispatch targets, and they carry the only thing
/// the runtime needs from them — `name` and `hook_type`, which it routes and
/// reports on. Recording the call and injecting pending session signals happen
/// around this call in `runtime::run_hook_command`, and write-surface
/// enforcement lives in `agents::policy::evaluate_write` behind the ACP client.
/// So there is nothing left for a handler body to decide.
#[expect(
    clippy::unnecessary_wraps,
    reason = "the signature must match the HookFn pointer type"
)]
fn allow(_ctx: &GuardContext) -> Result<HookOutcome, CliError> {
    Ok(HookOutcome::allow())
}

pub(crate) static TOOL_GUARD_HOOK: &dyn Hook =
    &StaticHook::effect("tool-guard", HookType::PreToolUse, allow);
pub(crate) static TOOL_RESULT_HOOK: &dyn Hook =
    &StaticHook::effect("tool-result", HookType::PostToolUse, allow);

#[cfg(test)]
pub(crate) fn all_hooks() -> [&'static dyn Hook; 2] {
    [TOOL_GUARD_HOOK, TOOL_RESULT_HOOK]
}
