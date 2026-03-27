use crate::hooks::adapters::{HookAgent, HookRegistration, adapter_for};
use crate::hooks::protocol::context::NormalizedEvent;

pub(super) fn process_agent_registrations(agent: HookAgent) -> Vec<HookRegistration> {
    let mut registrations = Vec::new();

    if matches!(
        agent,
        HookAgent::Claude | HookAgent::Gemini | HookAgent::Copilot
    ) {
        registrations.push(command_registration(
            "session-start",
            lifecycle_command(agent, "session-start"),
            NormalizedEvent::SessionStart,
            None,
        ));
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
        HookAgent::Claude => registrations.extend(claude_hooks(agent)),
        HookAgent::Codex => registrations.extend(codex_hooks(agent)),
        HookAgent::Copilot => registrations.extend(copilot_hooks(agent)),
        HookAgent::Gemini => registrations.extend(gemini_hooks(agent)),
    }

    registrations
}

fn codex_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    vec![
        command_registration(
            "prompt-submit",
            lifecycle_command(agent, "prompt-submit"),
            NormalizedEvent::UserPromptSubmit,
            None,
        ),
        hook_registration(
            agent,
            "guard-bash",
            NormalizedEvent::BeforeToolUse,
            Some("exec_command|shell_command|local_shell"),
        ),
        hook_registration(
            agent,
            "guard-write",
            NormalizedEvent::BeforeToolUse,
            Some(
                "apply_patch|edit_file|replace_in_file|write_file|create_file|edit|replace|write|create",
            ),
        ),
        hook_registration(agent, "guard-stop", NormalizedEvent::AgentStop, None),
        hook_registration(
            agent,
            "verify-bash",
            NormalizedEvent::AfterToolUse,
            Some("exec_command|shell_command|local_shell"),
        ),
        hook_registration(
            agent,
            "verify-write",
            NormalizedEvent::AfterToolUse,
            Some(
                "apply_patch|edit_file|replace_in_file|write_file|create_file|edit|replace|write|create",
            ),
        ),
        hook_registration(agent, "audit", NormalizedEvent::AfterToolUse, Some(".*")),
        hook_registration(agent, "context-agent", NormalizedEvent::SubagentStart, None),
        hook_registration(agent, "validate-agent", NormalizedEvent::SubagentStop, None),
    ]
}

fn claude_hooks(agent: HookAgent) -> Vec<HookRegistration> {
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

fn gemini_hooks(agent: HookAgent) -> Vec<HookRegistration> {
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

fn copilot_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    vec![
        command_registration(
            "prompt-submit",
            lifecycle_command(agent, "prompt-submit"),
            NormalizedEvent::UserPromptSubmit,
            None,
        ),
        hook_registration(agent, "guard-bash", NormalizedEvent::BeforeToolUse, None),
        hook_registration(agent, "guard-write", NormalizedEvent::BeforeToolUse, None),
        hook_registration(
            agent,
            "guard-question",
            NormalizedEvent::BeforeToolUse,
            None,
        ),
        hook_registration(agent, "guard-stop", NormalizedEvent::AgentStop, None),
        hook_registration(agent, "verify-bash", NormalizedEvent::AfterToolUse, None),
        hook_registration(agent, "verify-write", NormalizedEvent::AfterToolUse, None),
        hook_registration(
            agent,
            "verify-question",
            NormalizedEvent::AfterToolUse,
            None,
        ),
        hook_registration(agent, "audit", NormalizedEvent::AfterToolUse, None),
        hook_registration(
            agent,
            "enrich-failure",
            NormalizedEvent::AfterToolUseFailure,
            None,
        ),
    ]
}

pub(super) fn build_codex_config() -> String {
    concat!(
        "notify = [\"harness\", \"hook\", \"--agent\", \"codex\", \"suite:run\", \"audit-turn\"]\n",
        "\n",
        "# Project .codex/hooks.json entries are trust-gated and may be skipped when Codex\n",
        "# runs with allow_managed_hooks_only enabled. Keep lifecycle state ingestion here\n",
        "# so harness remains the source of truth for shared sessions and observe state.\n",
        "[features]\n",
        "codex_hooks = true\n",
        "\n",
        "[hooks]\n",
        "session_start = [\"harness\", \"agents\", \"session-start\", \"--agent\", \"codex\"]\n",
        "pre_compact = [\"harness\", \"pre-compact\"]\n",
        "session_end = [\"harness\", \"agents\", \"session-stop\", \"--agent\", \"codex\"]\n"
    )
    .to_string()
}

pub(super) fn lifecycle_command(agent: HookAgent, subcommand: &str) -> String {
    let (project_dir, agent_name) = match agent {
        HookAgent::Claude => ("\"$CLAUDE_PROJECT_DIR\"", "claude"),
        HookAgent::Gemini => ("\"${CLAUDE_PROJECT_DIR:-$GEMINI_PROJECT_DIR}\"", "gemini"),
        HookAgent::Codex => ("\"$PWD\"", "codex"),
        HookAgent::Copilot => ("\"$PWD\"", "copilot"),
    };
    match subcommand {
        "session-start" | "session-stop" | "prompt-submit" => {
            format!("harness agents {subcommand} --agent {agent_name} --project-dir {project_dir}")
        }
        _ => format!("harness {subcommand} --project-dir {project_dir}"),
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
