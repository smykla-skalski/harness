use crate::hooks::adapters::{HookAgent, HookRegistration, adapter_for};
use crate::hooks::protocol::context::NormalizedEvent;

pub(super) fn process_agent_registrations(agent: HookAgent) -> Vec<HookRegistration> {
    let mut registrations = Vec::new();

    // Lifecycle hooks registered for all runtimes. The session-start hook
    // also signals TUI readiness when HARNESS_AGENT_TUI_ID is set.
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

    match agent {
        HookAgent::Claude => registrations.extend(claude_hooks(agent)),
        HookAgent::Codex => registrations.extend(codex_hooks(agent)),
        HookAgent::Vibe => registrations.extend(vibe_hooks(agent)),
        HookAgent::OpenCode => registrations.extend(opencode_hooks(agent)),
        HookAgent::Copilot => registrations.extend(copilot_hooks(agent)),
        HookAgent::Gemini => registrations.extend(gemini_hooks(agent)),
    }

    registrations
}

fn codex_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    shared_runtime_hooks(agent)
}

fn vibe_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    shared_runtime_hooks(agent)
}

fn opencode_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    shared_runtime_hooks(agent)
}

fn shared_runtime_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    vec![
        command_registration(
            "prompt-submit",
            lifecycle_command(agent, "prompt-submit"),
            NormalizedEvent::UserPromptSubmit,
            None,
        ),
        command_registration(
            "repo-policy",
            repo_policy_command(agent),
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ),
        hook_registration(
            agent,
            "tool-guard",
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ),
        hook_registration(agent, "guard-stop", NormalizedEvent::AgentStop, None),
        hook_registration(
            agent,
            "tool-result",
            NormalizedEvent::AfterToolUse,
            Some(".*"),
        ),
        hook_registration(agent, "context-agent", NormalizedEvent::SubagentStart, None),
        hook_registration(agent, "validate-agent", NormalizedEvent::SubagentStop, None),
    ]
}

fn claude_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    vec![
        command_registration(
            "repo-policy",
            repo_policy_command(agent),
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ),
        hook_registration(
            agent,
            "tool-guard",
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ),
        hook_registration(agent, "guard-stop", NormalizedEvent::AgentStop, None),
        hook_registration(
            agent,
            "tool-result",
            NormalizedEvent::AfterToolUse,
            Some(".*"),
        ),
        hook_registration(
            agent,
            "tool-failure",
            NormalizedEvent::AfterToolUseFailure,
            Some(".*"),
        ),
        hook_registration(agent, "context-agent", NormalizedEvent::SubagentStart, None),
        hook_registration(agent, "validate-agent", NormalizedEvent::SubagentStop, None),
    ]
}

fn gemini_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    vec![
        command_registration(
            "repo-policy",
            repo_policy_command(agent),
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ),
        hook_registration(
            agent,
            "tool-guard",
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ),
        hook_registration(agent, "guard-stop", NormalizedEvent::AgentStop, None),
        hook_registration(
            agent,
            "tool-result",
            NormalizedEvent::AfterToolUse,
            Some(".*"),
        ),
        hook_registration(
            agent,
            "tool-failure",
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
        command_registration(
            "repo-policy",
            repo_policy_command(agent),
            NormalizedEvent::BeforeToolUse,
            None,
        ),
        hook_registration(agent, "tool-guard", NormalizedEvent::BeforeToolUse, None),
        hook_registration(agent, "guard-stop", NormalizedEvent::AgentStop, None),
        hook_registration(agent, "tool-result", NormalizedEvent::AfterToolUse, None),
        hook_registration(
            agent,
            "tool-failure",
            NormalizedEvent::AfterToolUseFailure,
            None,
        ),
    ]
}

pub(super) fn build_codex_config() -> String {
    concat!(
        "notify = [\"harness\", \"hook\", \"--agent\", \"codex\", \"suite:run\", \"audit-turn\"]\n",
        "\n",
        "# Enable official Codex hooks loaded from the adjacent .codex/hooks.json file.\n",
        "# Hook definitions stay in hooks.json; config.toml only turns the engine on.\n",
        "[features]\n",
        "codex_hooks = true\n"
    )
    .to_string()
}

pub(super) fn lifecycle_command(agent: HookAgent, subcommand: &str) -> String {
    let (project_dir, agent_name) = match agent {
        HookAgent::Claude => ("\"$CLAUDE_PROJECT_DIR\"", "claude"),
        HookAgent::Gemini => ("\"${CLAUDE_PROJECT_DIR:-$GEMINI_PROJECT_DIR}\"", "gemini"),
        HookAgent::Codex => ("\"$PWD\"", "codex"),
        HookAgent::Copilot => ("\"$PWD\"", "copilot"),
        HookAgent::Vibe => ("\"$PWD\"", "vibe"),
        HookAgent::OpenCode => ("\"$PWD\"", "opencode"),
    };
    match subcommand {
        "session-start" | "session-stop" | "prompt-submit" => {
            format!("harness agents {subcommand} --agent {agent_name} --project-dir {project_dir}")
        }
        _ => format!("harness {subcommand} --project-dir {project_dir}"),
    }
}

fn repo_policy_command(agent: HookAgent) -> String {
    format!(
        "harness agents repo-policy --agent {}",
        adapter_for(agent).name()
    )
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
