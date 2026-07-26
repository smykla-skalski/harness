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

/// Both tool-lifecycle hooks allow unconditionally. The guards that used to
/// decide here were reachable only for a skill no registration claims, so they
/// could never deny. The statics still matter: the runtime routes on their
/// `name` and `hook_type`, and records the call and injects pending session
/// signals around this call in `runtime::run_hook_command`.
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
