use clap::Parser;
use std::path::{Path, PathBuf};

use crate::hooks::protocol::hook_result::Decision;

use super::adapters::HookAgent;
use super::catalog::{GUARD_BASH_HOOK, VERIFY_BASH_HOOK, all_hooks};
use super::*;

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
    let mut names: Vec<&str> = all_hooks().iter().map(|hook| hook.name()).collect();
    names.sort_unstable();
    names.dedup();
    assert_eq!(names.len(), all_hooks().len());
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
    let result = super::runtime::hook_runtime_result(GUARD_BASH_HOOK, "KSH002", "error");
    assert_eq!(result.decision, Decision::Deny);
}

#[test]
fn hook_runtime_result_verify_is_warn() {
    let result = super::runtime::hook_runtime_result(VERIFY_BASH_HOOK, "KSH002", "error");
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
