use serde::Serialize;

use crate::errors::{CliError, CliErrorKind};
use crate::hooks::adapters::{HookAgent, HookRegistration, adapter_for};
use crate::hooks::protocol::context::NormalizedEvent;
use crate::hooks::runner_policy::managed_cluster_binaries;

pub(super) fn process_agent_registrations(agent: HookAgent) -> Vec<HookRegistration> {
    let mut registrations = vec![command_registration(
        "session-start",
        lifecycle_command(agent, "session-start"),
        NormalizedEvent::SessionStart,
        None,
    )];

    if matches!(agent, HookAgent::ClaudeCode | HookAgent::GeminiCli) {
        registrations.push(command_registration(
            "pre-compact",
            lifecycle_command(agent, "pre-compact"),
            NormalizedEvent::BeforeCompaction,
            None,
        ));
        registrations.push(command_registration(
            "session-stop",
            lifecycle_command(agent, "session-stop"),
            NormalizedEvent::SessionEnd,
            None,
        ));
    }

    match agent {
        HookAgent::ClaudeCode => registrations.extend(claude_code_hooks(agent)),
        HookAgent::GeminiCli => registrations.extend(gemini_cli_hooks(agent)),
        HookAgent::Codex => registrations.push(hook_registration(
            agent,
            "guard-stop",
            NormalizedEvent::AgentStop,
            None,
        )),
        HookAgent::OpenCode => unreachable!("handled separately"),
    }

    registrations
}

fn claude_code_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    vec![
        hook_registration(
            agent,
            "guard-bash",
            NormalizedEvent::BeforeToolUse,
            Some("Bash"),
        ),
        hook_registration(
            agent,
            "guard-write",
            NormalizedEvent::BeforeToolUse,
            Some("Write|Edit"),
        ),
        hook_registration(
            agent,
            "guard-question",
            NormalizedEvent::BeforeToolUse,
            Some("AskUserQuestion"),
        ),
        hook_registration(agent, "guard-stop", NormalizedEvent::AgentStop, None),
        hook_registration(
            agent,
            "verify-bash",
            NormalizedEvent::AfterToolUse,
            Some("Bash"),
        ),
        hook_registration(
            agent,
            "verify-write",
            NormalizedEvent::AfterToolUse,
            Some("Write|Edit"),
        ),
        hook_registration(
            agent,
            "verify-question",
            NormalizedEvent::AfterToolUse,
            Some("AskUserQuestion"),
        ),
        hook_registration(agent, "audit", NormalizedEvent::AfterToolUse, Some(".*")),
        hook_registration(
            agent,
            "enrich-failure",
            NormalizedEvent::AfterToolUseFailure,
            Some(".*"),
        ),
        hook_registration(agent, "context-agent", NormalizedEvent::SubagentStart, None),
        hook_registration(agent, "validate-agent", NormalizedEvent::SubagentStop, None),
    ]
}

fn gemini_cli_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    vec![
        hook_registration(
            agent,
            "guard-bash",
            NormalizedEvent::BeforeToolUse,
            Some("run_shell_command"),
        ),
        hook_registration(
            agent,
            "guard-write",
            NormalizedEvent::BeforeToolUse,
            Some("write_file|replace"),
        ),
        hook_registration(agent, "guard-stop", NormalizedEvent::AgentStop, None),
        hook_registration(
            agent,
            "verify-bash",
            NormalizedEvent::AfterToolUse,
            Some("run_shell_command"),
        ),
        hook_registration(
            agent,
            "verify-write",
            NormalizedEvent::AfterToolUse,
            Some("write_file|replace"),
        ),
        hook_registration(agent, "audit", NormalizedEvent::AfterToolUse, Some(".*")),
        hook_registration(
            agent,
            "enrich-failure",
            NormalizedEvent::AfterToolUseFailure,
            Some(".*"),
        ),
    ]
}

pub(super) fn build_codex_config() -> String {
    concat!(
        "notify = [\"harness\", \"hook\", \"--agent\", \"codex\", \"suite:run\", \"audit-turn\"]\n",
        "\n",
        "[features]\n",
        "codex_hooks = true\n"
    )
    .to_string()
}

pub(super) fn lifecycle_command(agent: HookAgent, subcommand: &str) -> String {
    let command_path = match subcommand {
        "session-start" => "setup session-start",
        "pre-compact" => "setup pre-compact",
        "session-stop" => "setup session-stop",
        _ => subcommand,
    };
    match agent {
        HookAgent::ClaudeCode => {
            format!("harness {command_path} --project-dir \"$CLAUDE_PROJECT_DIR\"")
        }
        HookAgent::GeminiCli => format!(
            "harness {command_path} --project-dir \"${{CLAUDE_PROJECT_DIR:-$GEMINI_PROJECT_DIR}}\""
        ),
        HookAgent::Codex => format!("harness {command_path} --project-dir \"$PWD\""),
        HookAgent::OpenCode => unreachable!("opencode lifecycle is handled by the bridge"),
    }
}

fn hook_registration(
    agent: HookAgent,
    name: &'static str,
    event: NormalizedEvent,
    matcher: Option<&str>,
) -> HookRegistration {
    HookRegistration {
        name,
        event,
        matcher: matcher.map(ToString::to_string),
        command: format!(
            "harness hook --agent {} suite:run {name}",
            adapter_for(agent).name()
        ),
    }
}

fn command_registration(
    name: &'static str,
    command: impl Into<String>,
    event: NormalizedEvent,
    matcher: Option<&str>,
) -> HookRegistration {
    HookRegistration {
        name,
        event,
        matcher: matcher.map(ToString::to_string),
        command: command.into(),
    }
}

#[derive(Serialize)]
struct OpenCodeToolBindings<'a> {
    bash: &'a str,
    write: &'a str,
    edit: &'a str,
}

pub(super) fn build_opencode_bridge() -> Result<String, CliError> {
    let denied_binaries = managed_cluster_binaries().into_iter().collect::<Vec<_>>();
    let denied_binaries_json = serde_json::to_string(&denied_binaries)
        .map_err(|error| CliErrorKind::serialize(format!("opencode denied binaries: {error}")))?;
    let tool_guards = serde_json::to_string(&OpenCodeToolBindings {
        bash: "guard-bash",
        write: "guard-write",
        edit: "guard-write",
    })
    .map_err(|error| CliErrorKind::serialize(format!("opencode tool guards: {error}")))?;
    let tool_verifiers = serde_json::to_string(&OpenCodeToolBindings {
        bash: "verify-bash",
        write: "verify-write",
        edit: "verify-write",
    })
    .map_err(|error| CliErrorKind::serialize(format!("opencode tool verifiers: {error}")))?;

    let bridge = include_str!("../../../resources/opencode/harness-bridge.ts")
        .replace("__DENIED_BINARY_HINTS__", &denied_binaries_json)
        .replace("__TOOL_GUARDS__", &tool_guards)
        .replace("__TOOL_VERIFIERS__", &tool_verifiers);

    Ok(bridge)
}
