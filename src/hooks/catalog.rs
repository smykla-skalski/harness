use crate::errors::CliError;
use crate::hooks::protocol::hook_result::HookResult;

use super::application::GuardContext;
use super::registry::Hook;
use super::{HookOutcome, HookType};

type LegacyHookFn = fn(&GuardContext) -> Result<HookResult, CliError>;
type EffectHookFn = fn(&GuardContext) -> Result<HookOutcome, CliError>;

enum HookExecutor {
    Legacy(LegacyHookFn),
    Effect(EffectHookFn),
}

struct StaticHook {
    name: &'static str,
    hook_type: HookType,
    executor: HookExecutor,
}

impl StaticHook {
    const fn legacy(name: &'static str, hook_type: HookType, execute: LegacyHookFn) -> Self {
        Self {
            name,
            hook_type,
            executor: HookExecutor::Legacy(execute),
        }
    }

    const fn effect(name: &'static str, hook_type: HookType, execute: EffectHookFn) -> Self {
        Self {
            name,
            hook_type,
            executor: HookExecutor::Effect(execute),
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
        match self.executor {
            HookExecutor::Legacy(execute) => execute(ctx).map(HookOutcome::from_hook_result),
            HookExecutor::Effect(execute) => execute(ctx),
        }
    }
}

pub(crate) static GUARD_BASH_HOOK: &dyn Hook = &StaticHook::legacy(
    "guard-bash",
    HookType::PreToolUse,
    super::guard_bash::execute,
);
pub(crate) static GUARD_WRITE_HOOK: &dyn Hook = &StaticHook::legacy(
    "guard-write",
    HookType::PreToolUse,
    super::guard_write::execute,
);
pub(crate) static GUARD_QUESTION_HOOK: &dyn Hook = &StaticHook::legacy(
    "guard-question",
    HookType::PreToolUse,
    super::guard_question::execute,
);
pub(crate) static GUARD_STOP_HOOK: &dyn Hook =
    &StaticHook::legacy("guard-stop", HookType::Blocking, super::guard_stop::execute);
pub(crate) static VERIFY_BASH_HOOK: &dyn Hook = &StaticHook::legacy(
    "verify-bash",
    HookType::PostToolUse,
    super::verify_bash::execute,
);
pub(crate) static VERIFY_WRITE_HOOK: &dyn Hook = &StaticHook::effect(
    "verify-write",
    HookType::PostToolUse,
    super::verify_write::execute,
);
pub(crate) static VERIFY_QUESTION_HOOK: &dyn Hook = &StaticHook::legacy(
    "verify-question",
    HookType::PostToolUse,
    super::verify_question::execute,
);
pub(crate) static AUDIT_HOOK: &dyn Hook =
    &StaticHook::effect("audit", HookType::PostToolUse, super::audit::execute);
pub(crate) static ENRICH_FAILURE_HOOK: &dyn Hook = &StaticHook::effect(
    "enrich-failure",
    HookType::PostToolUseFailure,
    super::enrich_failure::execute,
);
pub(crate) static CONTEXT_AGENT_HOOK: &dyn Hook = &StaticHook::effect(
    "context-agent",
    HookType::SubagentStart,
    super::context_agent::execute,
);
pub(crate) static VALIDATE_AGENT_HOOK: &dyn Hook = &StaticHook::effect(
    "validate-agent",
    HookType::SubagentStop,
    super::validate_agent::execute,
);

#[cfg(test)]
pub(crate) fn all_hooks() -> [&'static dyn Hook; 11] {
    [
        GUARD_BASH_HOOK,
        GUARD_WRITE_HOOK,
        GUARD_QUESTION_HOOK,
        GUARD_STOP_HOOK,
        VERIFY_BASH_HOOK,
        VERIFY_WRITE_HOOK,
        VERIFY_QUESTION_HOOK,
        AUDIT_HOOK,
        ENRICH_FAILURE_HOOK,
        CONTEXT_AGENT_HOOK,
        VALIDATE_AGENT_HOOK,
    ]
}
