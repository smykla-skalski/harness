use std::path::{Component, Path, PathBuf};

use clap::{Args, Subcommand};

use crate::errors::CliError;
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner::RunFile;

pub mod audit;
pub mod context_agent;
pub mod enrich_failure;
pub mod guard_bash;
pub mod guard_question;
pub mod guard_stop;
pub mod guard_write;
pub mod output;
pub mod validate_agent;
pub mod verify_bash;
pub mod verify_question;
pub mod verify_write;

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

/// One hook registration entry.
#[derive(Clone, Copy)]
pub struct HookSpec {
    pub name: &'static str,
    pub hook_type: HookType,
    pub execute: fn(&HookContext) -> Result<HookResult, CliError>,
}

impl HookSpec {
    const fn new(
        name: &'static str,
        hook_type: HookType,
        execute: fn(&HookContext) -> Result<HookResult, CliError>,
    ) -> Self {
        Self {
            name,
            hook_type,
            execute,
        }
    }
}

static GUARD_BASH: HookSpec =
    HookSpec::new("guard-bash", HookType::PreToolUse, guard_bash::execute);
static GUARD_WRITE: HookSpec =
    HookSpec::new("guard-write", HookType::PreToolUse, guard_write::execute);
static GUARD_QUESTION: HookSpec = HookSpec::new(
    "guard-question",
    HookType::PreToolUse,
    guard_question::execute,
);
static GUARD_STOP: HookSpec = HookSpec::new("guard-stop", HookType::Blocking, guard_stop::execute);
static VERIFY_BASH: HookSpec =
    HookSpec::new("verify-bash", HookType::PostToolUse, verify_bash::execute);
static VERIFY_WRITE: HookSpec =
    HookSpec::new("verify-write", HookType::PostToolUse, verify_write::execute);
static VERIFY_QUESTION: HookSpec = HookSpec::new(
    "verify-question",
    HookType::PostToolUse,
    verify_question::execute,
);
static AUDIT: HookSpec = HookSpec::new("audit", HookType::PostToolUse, audit::execute);
static ENRICH_FAILURE: HookSpec = HookSpec::new(
    "enrich-failure",
    HookType::PostToolUseFailure,
    enrich_failure::execute,
);
static CONTEXT_AGENT: HookSpec = HookSpec::new(
    "context-agent",
    HookType::SubagentStart,
    context_agent::execute,
);
static VALIDATE_AGENT: HookSpec = HookSpec::new(
    "validate-agent",
    HookType::SubagentStop,
    validate_agent::execute,
);

pub static ALL_HOOKS: [&HookSpec; 11] = [
    &GUARD_BASH,
    &GUARD_WRITE,
    &GUARD_QUESTION,
    &GUARD_STOP,
    &VERIFY_BASH,
    &VERIFY_WRITE,
    &VERIFY_QUESTION,
    &AUDIT,
    &ENRICH_FAILURE,
    &CONTEXT_AGENT,
    &VALIDATE_AGENT,
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
    /// Enrich failure context.
    EnrichFailure,
    /// Validate subagent startup context.
    ContextAgent,
    /// Validate subagent results.
    ValidateAgent,
}

impl HookCommand {
    #[must_use]
    pub fn spec(&self) -> &'static HookSpec {
        match self {
            Self::GuardBash => &GUARD_BASH,
            Self::GuardWrite => &GUARD_WRITE,
            Self::GuardQuestion => &GUARD_QUESTION,
            Self::GuardStop => &GUARD_STOP,
            Self::VerifyBash => &VERIFY_BASH,
            Self::VerifyWrite => &VERIFY_WRITE,
            Self::VerifyQuestion => &VERIFY_QUESTION,
            Self::Audit => &AUDIT,
            Self::EnrichFailure => &ENRICH_FAILURE,
            Self::ContextAgent => &CONTEXT_AGENT,
            Self::ValidateAgent => &VALIDATE_AGENT,
        }
    }

    #[must_use]
    pub fn name(&self) -> &'static str {
        self.spec().name
    }

    #[must_use]
    pub fn hook_type(&self) -> HookType {
        self.spec().hook_type
    }
}

/// Arguments for `harness hook`.
#[derive(Debug, Clone, Args)]
pub struct HookArgs {
    /// Skill name (suite:run or suite:new).
    #[arg(value_parser = clap::builder::PossibleValuesParser::new(crate::rules::SKILL_NAMES))]
    pub skill: String,
    /// Hook to run.
    #[command(subcommand)]
    pub hook: HookCommand,
}

fn hook_runtime_result(spec: &HookSpec, code: &str, message: &str) -> HookResult {
    if spec.hook_type.is_guard() {
        HookResult::deny(code, message)
    } else {
        HookResult::warn(code, message)
    }
}

fn format_hook_error_detail(spec: &HookSpec, error: &CliError) -> String {
    let mut parts = vec![format!("`{}` failed internally: {error}", spec.name)];
    if let Some(hint) = error.hint() {
        parts.push(format!("Hint: {hint}"));
    }
    if let Some(details) = error.details() {
        parts.push(format!("Details: {details}"));
    }
    parts.join(" ")
}

/// Execute a hook command: build context, dispatch, render output.
#[must_use]
pub fn run_hook_command(skill: &str, hook: &HookCommand) -> i32 {
    let spec = hook.spec();
    let ctx = match HookContext::from_stdin(skill) {
        Ok(ctx) => ctx,
        Err(error) => {
            let message = format!("`{}` received invalid hook payload: {error}", spec.name);
            let result = hook_runtime_result(spec, "KSH001", &message);
            let output = output::render_hook_output(spec.hook_type, &result);
            if !output.is_empty() {
                print!("{output}");
            }
            return 0;
        }
    };

    let result = match (spec.execute)(&ctx) {
        Ok(result) => result,
        Err(error) => {
            let detail = format_hook_error_detail(spec, &error);
            hook_runtime_result(spec, "KSH002", &detail)
        }
    };

    let output = output::render_hook_output(spec.hook_type, &result);
    if !output.is_empty() {
        print!("{output}");
    }
    0
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
    use super::*;
    use crate::hook::Decision;

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
        assert!(hint.contains("harness record"));
    }

    #[test]
    fn control_file_hint_other() {
        let hint = control_file_hint(Path::new("run-report.md"));
        assert!(hint.contains("harness report group"));
    }

    #[test]
    fn hook_names_are_unique() {
        let mut names: Vec<&str> = ALL_HOOKS.iter().map(|spec| spec.name).collect();
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
        let result = hook_runtime_result(&GUARD_BASH, "KSH002", "error");
        assert_eq!(result.decision, Decision::Deny);
    }

    #[test]
    fn hook_runtime_result_verify_is_warn() {
        let result = hook_runtime_result(&VERIFY_BASH, "KSH002", "error");
        assert_eq!(result.decision, Decision::Warn);
    }
}
