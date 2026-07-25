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

pub(crate) static TOOL_GUARD_HOOK: &dyn Hook = &StaticHook::effect(
    "tool-guard",
    HookType::PreToolUse,
    super::tool_guard::execute,
);
pub(crate) static TOOL_RESULT_HOOK: &dyn Hook = &StaticHook::effect(
    "tool-result",
    HookType::PostToolUse,
    super::tool_result::execute,
);
pub(crate) static TOOL_FAILURE_HOOK: &dyn Hook = &StaticHook::effect(
    "tool-failure",
    HookType::PostToolUseFailure,
    super::tool_failure::execute,
);

#[cfg(test)]
pub(crate) fn all_hooks() -> [&'static dyn Hook; 3] {
    [TOOL_GUARD_HOOK, TOOL_RESULT_HOOK, TOOL_FAILURE_HOOK]
}
