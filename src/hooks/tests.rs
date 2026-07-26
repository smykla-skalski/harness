use clap::Parser;

use crate::hooks::protocol::hook_result::Decision;

use super::adapters::HookAgent;
use super::catalog::{TOOL_GUARD_HOOK, TOOL_RESULT_HOOK, all_hooks};
use super::*;

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
        HookCommand::ToolGuard,
        HookCommand::ToolResult,
        HookCommand::AuditTurn(AuditTurnArgs { payload: None }),
    ] {
        assert!(
            matches!(
                hook.hook_type(),
                HookType::PreToolUse | HookType::PostToolUse
            ),
            "{} had no hook type",
            hook.name()
        );
    }
}

#[test]
fn hook_runtime_result_guard_is_deny() {
    let result = super::runtime::hook_runtime_result(TOOL_GUARD_HOOK, "KSH002", "error");
    assert_eq!(result.decision, Decision::Deny);
}

#[test]
fn hook_runtime_result_verify_is_warn() {
    let result = super::runtime::hook_runtime_result(TOOL_RESULT_HOOK, "KSH002", "error");
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
