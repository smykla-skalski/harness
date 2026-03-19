use std::path::{Component, Path, PathBuf};

use clap::{Args, Subcommand};

use crate::errors::{CliError, CliErrorKind};
use crate::kernel::run_surface::RunFile;
use crate::kernel::skills::SKILL_NAMES;

use self::adapters::{HookAgent, adapter_for};
use self::application::{GuardContext, prepare_normalized_context};
use self::protocol::context::NormalizedEvent;
use self::protocol::hook_result::HookResult;
use self::protocol::result::NormalizedHookResult;
use self::registry::{Hook, HookEngine};

pub mod application;
pub mod debug;
pub mod protocol;
pub mod runner_policy;
pub mod session;

pub mod adapters;
pub mod audit;
pub mod context_agent;
mod effects;
pub mod enrich_failure;
pub mod guard_bash;
pub mod guard_question;
pub mod guard_stop;
pub mod guard_write;
pub mod guards;
pub mod registry;
pub mod validate_agent;
pub mod verify_bash;
pub mod verify_question;
pub mod verify_write;

pub use self::effects::{HookEffect, HookOutcome};
pub use self::protocol::{context, hook_result, output, payloads, result};

/// Hook lifecycle categories.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookType {
    PreToolUse,
    PostToolUse,
    PostToolUseFailure,
    SubagentStart,
    SubagentStop,
    Blocking,
}

impl HookType {
    #[must_use]
    pub const fn is_guard(self) -> bool {
        matches!(self, Self::PreToolUse | Self::Blocking)
    }
}

macro_rules! define_legacy_hook {
    ($static_name:ident, $struct_name:ident, $hook_name:literal, $hook_type:expr, $module:ident) => {
        struct $struct_name;

        impl Hook for $struct_name {
            fn name(&self) -> &str {
                $hook_name
            }

            fn hook_type(&self) -> HookType {
                $hook_type
            }

            fn execute(&self, ctx: &GuardContext) -> Result<HookOutcome, CliError> {
                $module::execute(ctx).map(HookOutcome::from_hook_result)
            }
        }

        static $static_name: $struct_name = $struct_name;
    };
}

macro_rules! define_effect_hook {
    ($static_name:ident, $struct_name:ident, $hook_name:literal, $hook_type:expr, $module:ident) => {
        struct $struct_name;

        impl Hook for $struct_name {
            fn name(&self) -> &str {
                $hook_name
            }

            fn hook_type(&self) -> HookType {
                $hook_type
            }

            fn execute(&self, ctx: &GuardContext) -> Result<HookOutcome, CliError> {
                $module::execute(ctx)
            }
        }

        static $static_name: $struct_name = $struct_name;
    };
}

define_legacy_hook!(
    GUARD_BASH_HOOK,
    GuardBashHook,
    "guard-bash",
    HookType::PreToolUse,
    guard_bash
);
define_legacy_hook!(
    GUARD_WRITE_HOOK,
    GuardWriteHook,
    "guard-write",
    HookType::PreToolUse,
    guard_write
);
define_legacy_hook!(
    GUARD_QUESTION_HOOK,
    GuardQuestionHook,
    "guard-question",
    HookType::PreToolUse,
    guard_question
);
define_legacy_hook!(
    GUARD_STOP_HOOK,
    GuardStopHook,
    "guard-stop",
    HookType::Blocking,
    guard_stop
);
define_legacy_hook!(
    VERIFY_BASH_HOOK,
    VerifyBashHook,
    "verify-bash",
    HookType::PostToolUse,
    verify_bash
);
define_effect_hook!(
    VERIFY_WRITE_HOOK,
    VerifyWriteHook,
    "verify-write",
    HookType::PostToolUse,
    verify_write
);
define_legacy_hook!(
    VERIFY_QUESTION_HOOK,
    VerifyQuestionHook,
    "verify-question",
    HookType::PostToolUse,
    verify_question
);
define_effect_hook!(AUDIT_HOOK, AuditHook, "audit", HookType::PostToolUse, audit);
define_effect_hook!(
    ENRICH_FAILURE_HOOK,
    EnrichFailureHook,
    "enrich-failure",
    HookType::PostToolUseFailure,
    enrich_failure
);
define_effect_hook!(
    CONTEXT_AGENT_HOOK,
    ContextAgentHook,
    "context-agent",
    HookType::SubagentStart,
    context_agent
);
define_effect_hook!(
    VALIDATE_AGENT_HOOK,
    ValidateAgentHook,
    "validate-agent",
    HookType::SubagentStop,
    validate_agent
);

pub static ALL_HOOKS: [&'static dyn Hook; 11] = [
    &GUARD_BASH_HOOK,
    &GUARD_WRITE_HOOK,
    &GUARD_QUESTION_HOOK,
    &GUARD_STOP_HOOK,
    &VERIFY_BASH_HOOK,
    &VERIFY_WRITE_HOOK,
    &VERIFY_QUESTION_HOOK,
    &AUDIT_HOOK,
    &ENRICH_FAILURE_HOOK,
    &CONTEXT_AGENT_HOOK,
    &VALIDATE_AGENT_HOOK,
];

/// Available hooks.
#[derive(Debug, Clone, Subcommand)]
#[non_exhaustive]
pub enum HookCommand {
    /// Guard Bash tool usage.
    GuardBash,
    /// Guard file write operations.
    GuardWrite,
    /// Guard `AskUserQuestion` prompts.
    GuardQuestion,
    /// Guard stop and session end.
    GuardStop,
    /// Verify Bash tool results.
    VerifyBash,
    /// Verify file write results.
    VerifyWrite,
    /// Verify question answers.
    VerifyQuestion,
    /// Audit hook events.
    Audit,
    /// Audit a Codex turn-complete notification.
    AuditTurn(AuditTurnArgs),
    /// Enrich failure context.
    EnrichFailure,
    /// Validate subagent startup context.
    ContextAgent,
    /// Validate subagent results.
    ValidateAgent,
}

/// Arguments for the Codex notify-based audit shim.
#[derive(Debug, Clone, Default, Args)]
pub struct AuditTurnArgs {
    /// Raw Codex notify payload passed as `argv[1]`.
    #[arg(hide = true)]
    pub payload: Option<String>,
}

impl HookCommand {
    #[must_use]
    pub fn hook(&self) -> &'static dyn Hook {
        match self {
            Self::GuardBash => &GUARD_BASH_HOOK,
            Self::GuardWrite => &GUARD_WRITE_HOOK,
            Self::GuardQuestion => &GUARD_QUESTION_HOOK,
            Self::GuardStop => &GUARD_STOP_HOOK,
            Self::VerifyBash => &VERIFY_BASH_HOOK,
            Self::VerifyWrite => &VERIFY_WRITE_HOOK,
            Self::VerifyQuestion => &VERIFY_QUESTION_HOOK,
            Self::Audit | Self::AuditTurn(_) => &AUDIT_HOOK,
            Self::EnrichFailure => &ENRICH_FAILURE_HOOK,
            Self::ContextAgent => &CONTEXT_AGENT_HOOK,
            Self::ValidateAgent => &VALIDATE_AGENT_HOOK,
        }
    }

    #[must_use]
    pub fn name(&self) -> &'static str {
        match self {
            Self::AuditTurn(_) => "audit-turn",
            _ => self.hook().name(),
        }
    }

    #[must_use]
    pub fn hook_type(&self) -> HookType {
        self.hook().hook_type()
    }

    #[must_use]
    fn inline_payload(&self) -> Option<&str> {
        match self {
            Self::AuditTurn(args) => args.payload.as_deref(),
            _ => None,
        }
    }
}

/// Arguments for `harness hook`.
#[derive(Debug, Clone, Args)]
pub struct HookArgs {
    /// Hook transport/agent protocol.
    #[arg(long, value_enum, default_value_t = HookAgent::ClaudeCode)]
    pub agent: HookAgent,
    /// Skill name (suite:run or suite:new).
    #[arg(value_parser = clap::builder::PossibleValuesParser::new(SKILL_NAMES))]
    pub skill: String,
    /// Hook to run.
    #[command(subcommand)]
    pub hook: HookCommand,
}

fn hook_runtime_result(hook: &dyn Hook, code: &str, message: &str) -> HookResult {
    if hook.hook_type().is_guard() {
        HookResult::deny(code, message)
    } else {
        HookResult::warn(code, message)
    }
}

pub(crate) fn dispatch_by_skill<RunnerFn, AuthorFn>(
    ctx: &GuardContext,
    runner: RunnerFn,
    author: AuthorFn,
) -> Result<HookResult, CliError>
where
    RunnerFn: FnOnce(&GuardContext) -> Result<HookResult, CliError>,
    AuthorFn: FnOnce(&GuardContext) -> Result<HookResult, CliError>,
{
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    if ctx.is_suite_author() {
        return author(ctx);
    }
    runner(ctx)
}

pub(crate) fn dispatch_outcome_by_skill<RunnerFn, AuthorFn>(
    ctx: &GuardContext,
    runner: RunnerFn,
    author: AuthorFn,
) -> Result<HookOutcome, CliError>
where
    RunnerFn: FnOnce(&GuardContext) -> Result<HookOutcome, CliError>,
    AuthorFn: FnOnce(&GuardContext) -> Result<HookOutcome, CliError>,
{
    if !ctx.skill_active {
        return Ok(HookOutcome::allow());
    }
    if ctx.is_suite_author() {
        return author(ctx);
    }
    runner(ctx)
}

fn format_hook_error_detail(hook: &dyn Hook, error: &CliError) -> String {
    let mut parts = vec![format!("`{}` failed internally: {error}", hook.name())];
    if let Some(hint) = error.hint() {
        parts.push(format!("Hint: {hint}"));
    }
    if let Some(details) = error.details() {
        parts.push(format!("Details: {details}"));
    }
    parts.join(" ")
}

fn default_event_for_hook(hook_type: HookType) -> NormalizedEvent {
    match hook_type {
        HookType::PreToolUse => NormalizedEvent::BeforeToolUse,
        HookType::PostToolUse => NormalizedEvent::AfterToolUse,
        HookType::PostToolUseFailure => NormalizedEvent::AfterToolUseFailure,
        HookType::SubagentStart => NormalizedEvent::SubagentStart,
        HookType::SubagentStop => NormalizedEvent::SubagentStop,
        HookType::Blocking => NormalizedEvent::AgentStop,
    }
}

fn default_event_for_command(hook: &HookCommand) -> NormalizedEvent {
    match hook {
        HookCommand::AuditTurn(_) => NormalizedEvent::Notification,
        _ => default_event_for_hook(hook.hook_type()),
    }
}

fn render_runtime_error(
    agent: HookAgent,
    hook: &dyn Hook,
    event: &NormalizedEvent,
    code: &str,
    message: &str,
) -> i32 {
    let result = NormalizedHookResult::from_hook_result(hook_runtime_result(hook, code, message));
    let rendered = adapter_for(agent).render_output(&result, event);
    if !rendered.stdout.is_empty() {
        print!("{}", rendered.stdout);
    }
    rendered.exit_code
}

fn read_stdin_bytes() -> Result<Vec<u8>, CliError> {
    use std::io::{self, Read};

    let mut bytes = Vec::new();
    io::stdin().read_to_end(&mut bytes).map_err(|error| {
        CliError::from(CliErrorKind::hook_payload_invalid(format!(
            "failed to read stdin: {error}"
        )))
    })?;
    Ok(bytes)
}

fn read_hook_input_bytes(hook: &HookCommand) -> Result<Vec<u8>, CliError> {
    if let Some(payload) = hook.inline_payload() {
        return Ok(payload.as_bytes().to_vec());
    }
    read_stdin_bytes()
}

/// Execute a hook command through the layered adapter/engine stack.
#[must_use]
pub fn run_hook_command(agent: HookAgent, skill: &str, hook: &HookCommand) -> i32 {
    let hook_impl = hook.hook();
    let hook_name = hook.name();
    let event = default_event_for_command(hook);
    let raw = match read_hook_input_bytes(hook) {
        Ok(raw) => raw,
        Err(error) => {
            let message = format!("`{hook_name}` received invalid hook payload: {error}");
            return render_runtime_error(agent, hook_impl, &event, "KSH001", &message);
        }
    };

    let adapter = adapter_for(agent);
    let normalized = match adapter.parse_input(&raw) {
        Ok(context) => prepare_normalized_context(context, skill, event),
        Err(error) => {
            let message = format!("`{hook_name}` received invalid hook payload: {error}");
            return render_runtime_error(agent, hook_impl, &event, "KSH001", &message);
        }
    };
    let render_event = normalized.event.clone();

    let engine = HookEngine::new();
    let result = match engine.execute(hook_impl, normalized) {
        Ok(result) => result,
        Err(error) => {
            let detail = format_hook_error_detail(hook_impl, &error);
            NormalizedHookResult::from_hook_result(hook_runtime_result(
                hook_impl, "KSH002", &detail,
            ))
        }
    };

    let rendered = adapter.render_output(&result, &render_event);
    if !rendered.stdout.is_empty() {
        print!("{}", rendered.stdout);
    }
    rendered.exit_code
}

/// Normalize a path by resolving `.` and `..` segments without touching the
/// filesystem. Unlike `std::fs::canonicalize`, this works on paths that do not
/// exist yet.
pub(crate) fn normalize_path(path: &Path) -> PathBuf {
    let mut parts: Vec<Component<'_>> = Vec::new();
    for comp in path.components() {
        match comp {
            Component::CurDir => {}
            Component::ParentDir => {
                if let Some(Component::Normal(_)) = parts.last() {
                    parts.pop();
                } else {
                    parts.push(comp);
                }
            }
            _ => parts.push(comp),
        }
    }
    parts.iter().collect()
}

/// Returns `true` when `path` refers to a harness-managed run control file
/// inside `run_dir`.
pub(crate) fn is_command_owned_run_file(path: &Path, run_dir: &Path) -> bool {
    let norm = normalize_path(path);
    RunFile::ALL
        .iter()
        .filter(|f| f.is_direct_write_denied())
        .any(|f| norm == normalize_path(&run_dir.join(f.to_string())))
}

/// Provides a user-facing hint for a denied control-file write.
pub(crate) fn control_file_hint(path: &Path) -> &'static str {
    let name = path.file_name().map_or("", |n| n.to_str().unwrap_or(""));
    if name == "command-log.md" {
        RunFile::COMMAND_LOG_HINT
    } else {
        RunFile::CONTROL_HINT
    }
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use super::*;
    use crate::hooks::protocol::hook_result::Decision;

    #[test]
    fn normalize_path_resolves_dot_dot() {
        let path = Path::new("/a/b/../c");
        assert_eq!(normalize_path(path), PathBuf::from("/a/c"));
    }

    #[test]
    fn normalize_path_resolves_dot() {
        let path = Path::new("/a/./b/./c");
        assert_eq!(normalize_path(path), PathBuf::from("/a/b/c"));
    }

    #[test]
    fn normalize_path_preserves_absolute() {
        let path = Path::new("/a/b/c");
        assert_eq!(normalize_path(path), PathBuf::from("/a/b/c"));
    }

    #[test]
    fn is_command_owned_run_report() {
        assert!(is_command_owned_run_file(
            Path::new("/runs/run-1/run-report.md"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn is_command_owned_run_status() {
        assert!(is_command_owned_run_file(
            Path::new("/runs/run-1/run-status.json"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn is_command_owned_runner_state() {
        assert!(is_command_owned_run_file(
            Path::new("/runs/run-1/suite-run-state.json"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn is_command_owned_command_log() {
        assert!(is_command_owned_run_file(
            Path::new("/runs/run-1/commands/command-log.md"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn is_not_command_owned_artifact() {
        assert!(!is_command_owned_run_file(
            Path::new("/runs/run-1/artifacts/state.json"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn is_not_command_owned_different_run() {
        assert!(!is_command_owned_run_file(
            Path::new("/runs/run-2/run-report.md"),
            Path::new("/runs/run-1")
        ));
    }

    #[test]
    fn control_file_hint_command_log() {
        let hint = control_file_hint(Path::new("commands/command-log.md"));
        assert!(hint.contains("harness run record"));
    }

    #[test]
    fn control_file_hint_other() {
        let hint = control_file_hint(Path::new("run-report.md"));
        assert!(hint.contains("harness run report group"));
    }

    #[test]
    fn hook_names_are_unique() {
        let mut names: Vec<&str> = ALL_HOOKS.iter().map(|hook| hook.name()).collect();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), ALL_HOOKS.len());
    }

    #[test]
    fn hook_command_types_are_exhaustive() {
        for hook in [
            HookCommand::GuardBash,
            HookCommand::GuardWrite,
            HookCommand::GuardQuestion,
            HookCommand::GuardStop,
            HookCommand::VerifyBash,
            HookCommand::VerifyWrite,
            HookCommand::VerifyQuestion,
            HookCommand::Audit,
            HookCommand::AuditTurn(AuditTurnArgs { payload: None }),
            HookCommand::EnrichFailure,
            HookCommand::ContextAgent,
            HookCommand::ValidateAgent,
        ] {
            assert!(
                matches!(
                    hook.hook_type(),
                    HookType::PreToolUse
                        | HookType::PostToolUse
                        | HookType::PostToolUseFailure
                        | HookType::SubagentStart
                        | HookType::SubagentStop
                        | HookType::Blocking
                ),
                "{} had no hook type",
                hook.name()
            );
        }
    }

    #[test]
    fn hook_runtime_result_guard_is_deny() {
        let result = hook_runtime_result(&GUARD_BASH_HOOK, "KSH002", "error");
        assert_eq!(result.decision, Decision::Deny);
    }

    #[test]
    fn hook_runtime_result_verify_is_warn() {
        let result = hook_runtime_result(&VERIFY_BASH_HOOK, "KSH002", "error");
        assert_eq!(result.decision, Decision::Warn);
    }

    #[test]
    fn hook_args_accept_audit_turn_payload_arg() {
        #[derive(clap::Parser)]
        struct TestCli {
            #[command(flatten)]
            hook: HookArgs,
        }

        let cli = TestCli::try_parse_from([
            "harness",
            "--agent",
            "codex",
            "suite:run",
            "audit-turn",
            r#"{"type":"agent-turn-complete"}"#,
        ])
        .unwrap();

        assert_eq!(cli.hook.agent, HookAgent::Codex);
        assert_eq!(cli.hook.skill, "suite:run");
        assert!(matches!(
            cli.hook.hook,
            HookCommand::AuditTurn(AuditTurnArgs {
                payload: Some(ref payload)
            }) if payload == r#"{"type":"agent-turn-complete"}"#
        ));
    }
}
