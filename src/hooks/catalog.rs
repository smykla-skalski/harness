use crate::errors::CliError;

use super::application::GuardContext;
use super::registry::Hook;
use super::{HookOutcome, HookType};

macro_rules! define_legacy_hook {
    ($static_name:ident, $struct_name:ident, $hook_name:literal, $hook_type:expr, $execute:path) => {
        struct $struct_name;

        impl Hook for $struct_name {
            fn name(&self) -> &str {
                $hook_name
            }

            fn hook_type(&self) -> HookType {
                $hook_type
            }

            fn execute(&self, ctx: &GuardContext) -> Result<HookOutcome, CliError> {
                $execute(ctx).map(HookOutcome::from_hook_result)
            }
        }

        pub(crate) static $static_name: &dyn Hook = &$struct_name;
    };
}

macro_rules! define_effect_hook {
    ($static_name:ident, $struct_name:ident, $hook_name:literal, $hook_type:expr, $execute:path) => {
        struct $struct_name;

        impl Hook for $struct_name {
            fn name(&self) -> &str {
                $hook_name
            }

            fn hook_type(&self) -> HookType {
                $hook_type
            }

            fn execute(&self, ctx: &GuardContext) -> Result<HookOutcome, CliError> {
                $execute(ctx)
            }
        }

        pub(crate) static $static_name: &dyn Hook = &$struct_name;
    };
}

define_legacy_hook!(
    GUARD_BASH_HOOK,
    GuardBashHook,
    "guard-bash",
    HookType::PreToolUse,
    super::guard_bash::execute
);
define_legacy_hook!(
    GUARD_WRITE_HOOK,
    GuardWriteHook,
    "guard-write",
    HookType::PreToolUse,
    super::guard_write::execute
);
define_legacy_hook!(
    GUARD_QUESTION_HOOK,
    GuardQuestionHook,
    "guard-question",
    HookType::PreToolUse,
    super::guard_question::execute
);
define_legacy_hook!(
    GUARD_STOP_HOOK,
    GuardStopHook,
    "guard-stop",
    HookType::Blocking,
    super::guard_stop::execute
);
define_legacy_hook!(
    VERIFY_BASH_HOOK,
    VerifyBashHook,
    "verify-bash",
    HookType::PostToolUse,
    super::verify_bash::execute
);
define_effect_hook!(
    VERIFY_WRITE_HOOK,
    VerifyWriteHook,
    "verify-write",
    HookType::PostToolUse,
    super::verify_write::execute
);
define_legacy_hook!(
    VERIFY_QUESTION_HOOK,
    VerifyQuestionHook,
    "verify-question",
    HookType::PostToolUse,
    super::verify_question::execute
);
define_effect_hook!(
    AUDIT_HOOK,
    AuditHook,
    "audit",
    HookType::PostToolUse,
    super::audit::execute
);
define_effect_hook!(
    ENRICH_FAILURE_HOOK,
    EnrichFailureHook,
    "enrich-failure",
    HookType::PostToolUseFailure,
    super::enrich_failure::execute
);
define_effect_hook!(
    CONTEXT_AGENT_HOOK,
    ContextAgentHook,
    "context-agent",
    HookType::SubagentStart,
    super::context_agent::execute
);
define_effect_hook!(
    VALIDATE_AGENT_HOOK,
    ValidateAgentHook,
    "validate-agent",
    HookType::SubagentStop,
    super::validate_agent::execute
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
