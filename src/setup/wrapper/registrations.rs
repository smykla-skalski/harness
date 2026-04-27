use crate::feature_flags::RuntimeHookFlags;
use crate::hooks::adapters::{HookAgent, HookRegistration, adapter_for};
use crate::hooks::protocol::context::NormalizedEvent;

pub(super) fn process_agent_registrations(
    agent: HookAgent,
    flags: RuntimeHookFlags,
) -> Vec<HookRegistration> {
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
        HookAgent::Claude => registrations.extend(claude_hooks(agent, flags)),
        HookAgent::Codex => registrations.extend(codex_hooks(agent, flags)),
        HookAgent::Vibe => registrations.extend(vibe_hooks(agent, flags)),
        HookAgent::OpenCode => registrations.extend(opencode_hooks(agent, flags)),
        HookAgent::Copilot => registrations.extend(copilot_hooks(agent, flags)),
        HookAgent::Gemini => registrations.extend(gemini_hooks(agent, flags)),
    }

    registrations
}

fn codex_hooks(agent: HookAgent, flags: RuntimeHookFlags) -> Vec<HookRegistration> {
    shared_runtime_hooks(agent, flags)
}

fn vibe_hooks(agent: HookAgent, flags: RuntimeHookFlags) -> Vec<HookRegistration> {
    shared_runtime_hooks(agent, flags)
}

fn opencode_hooks(agent: HookAgent, flags: RuntimeHookFlags) -> Vec<HookRegistration> {
    shared_runtime_hooks(agent, flags)
}

fn shared_runtime_hooks(agent: HookAgent, flags: RuntimeHookFlags) -> Vec<HookRegistration> {
    let mut hooks = vec![command_registration(
        "prompt-submit",
        lifecycle_command(agent, "prompt-submit"),
        NormalizedEvent::UserPromptSubmit,
        None,
    )];
    if flags.repo_policy {
        hooks.push(command_registration(
            "repo-policy",
            repo_policy_command(agent),
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ));
    }
    hooks.push(hook_registration(
        agent,
        "tool-guard",
        NormalizedEvent::BeforeToolUse,
        Some(".*"),
    ));
    if flags.suite_hooks {
        hooks.push(hook_registration(
            agent,
            "guard-stop",
            NormalizedEvent::AgentStop,
            None,
        ));
    }
    hooks.push(hook_registration(
        agent,
        "tool-result",
        NormalizedEvent::AfterToolUse,
        Some(".*"),
    ));
    if flags.suite_hooks {
        hooks.push(hook_registration(
            agent,
            "context-agent",
            NormalizedEvent::SubagentStart,
            None,
        ));
        hooks.push(hook_registration(
            agent,
            "validate-agent",
            NormalizedEvent::SubagentStop,
            None,
        ));
    }
    hooks
}

fn claude_hooks(agent: HookAgent, flags: RuntimeHookFlags) -> Vec<HookRegistration> {
    let mut hooks = Vec::new();
    if flags.repo_policy {
        hooks.push(command_registration(
            "repo-policy",
            repo_policy_command(agent),
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ));
    }
    hooks.push(hook_registration(
        agent,
        "tool-guard",
        NormalizedEvent::BeforeToolUse,
        Some(".*"),
    ));
    if flags.suite_hooks {
        hooks.push(hook_registration(
            agent,
            "guard-stop",
            NormalizedEvent::AgentStop,
            None,
        ));
    }
    hooks.push(hook_registration(
        agent,
        "tool-result",
        NormalizedEvent::AfterToolUse,
        Some(".*"),
    ));
    if flags.suite_hooks {
        hooks.push(hook_registration(
            agent,
            "tool-failure",
            NormalizedEvent::AfterToolUseFailure,
            Some(".*"),
        ));
        hooks.push(hook_registration(
            agent,
            "context-agent",
            NormalizedEvent::SubagentStart,
            None,
        ));
        hooks.push(hook_registration(
            agent,
            "validate-agent",
            NormalizedEvent::SubagentStop,
            None,
        ));
    }
    hooks
}

fn gemini_hooks(agent: HookAgent, flags: RuntimeHookFlags) -> Vec<HookRegistration> {
    let mut hooks = Vec::new();
    if flags.repo_policy {
        hooks.push(command_registration(
            "repo-policy",
            repo_policy_command(agent),
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ));
    }
    hooks.push(hook_registration(
        agent,
        "tool-guard",
        NormalizedEvent::BeforeToolUse,
        Some(".*"),
    ));
    if flags.suite_hooks {
        hooks.push(hook_registration(
            agent,
            "guard-stop",
            NormalizedEvent::AgentStop,
            None,
        ));
    }
    hooks.push(hook_registration(
        agent,
        "tool-result",
        NormalizedEvent::AfterToolUse,
        Some(".*"),
    ));
    if flags.suite_hooks {
        hooks.push(hook_registration(
            agent,
            "tool-failure",
            NormalizedEvent::AfterToolUseFailure,
            Some(".*"),
        ));
    }
    hooks
}

fn copilot_hooks(agent: HookAgent, flags: RuntimeHookFlags) -> Vec<HookRegistration> {
    let mut hooks = vec![command_registration(
        "prompt-submit",
        lifecycle_command(agent, "prompt-submit"),
        NormalizedEvent::UserPromptSubmit,
        None,
    )];
    if flags.repo_policy {
        hooks.push(command_registration(
            "repo-policy",
            repo_policy_command(agent),
            NormalizedEvent::BeforeToolUse,
            None,
        ));
    }
    hooks.push(hook_registration(
        agent,
        "tool-guard",
        NormalizedEvent::BeforeToolUse,
        None,
    ));
    if flags.suite_hooks {
        hooks.push(hook_registration(
            agent,
            "guard-stop",
            NormalizedEvent::AgentStop,
            None,
        ));
    }
    hooks.push(hook_registration(
        agent,
        "tool-result",
        NormalizedEvent::AfterToolUse,
        None,
    ));
    if flags.suite_hooks {
        hooks.push(hook_registration(
            agent,
            "tool-failure",
            NormalizedEvent::AfterToolUseFailure,
            None,
        ));
    }
    hooks
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

#[cfg(test)]
mod tests {
    use super::*;

    fn names(regs: &[HookRegistration]) -> Vec<&'static str> {
        regs.iter().map(|r| r.name).collect()
    }

    #[test]
    fn defaults_omit_suite_and_repo_policy_hooks_for_claude() {
        let regs = process_agent_registrations(HookAgent::Claude, RuntimeHookFlags::default());
        let collected = names(&regs);
        assert!(!collected.contains(&"guard-stop"));
        assert!(!collected.contains(&"context-agent"));
        assert!(!collected.contains(&"validate-agent"));
        assert!(!collected.contains(&"tool-failure"));
        assert!(!collected.contains(&"repo-policy"));
        // Lifecycle and tool-guard/tool-result must still be present.
        assert!(collected.contains(&"session-start"));
        assert!(collected.contains(&"tool-guard"));
        assert!(collected.contains(&"tool-result"));
    }

    #[test]
    fn defaults_omit_suite_and_repo_policy_hooks_for_codex() {
        let regs = process_agent_registrations(HookAgent::Codex, RuntimeHookFlags::default());
        let collected = names(&regs);
        assert!(!collected.contains(&"guard-stop"));
        assert!(!collected.contains(&"context-agent"));
        assert!(!collected.contains(&"validate-agent"));
        assert!(!collected.contains(&"repo-policy"));
        assert!(collected.contains(&"prompt-submit"));
        assert!(collected.contains(&"tool-guard"));
    }

    #[test]
    fn enabling_only_suite_hooks_keeps_repo_policy_off() {
        let flags = RuntimeHookFlags {
            suite_hooks: true,
            repo_policy: false,
        };
        let regs = process_agent_registrations(HookAgent::Claude, flags);
        let collected = names(&regs);
        assert!(collected.contains(&"guard-stop"));
        assert!(collected.contains(&"context-agent"));
        assert!(collected.contains(&"validate-agent"));
        assert!(collected.contains(&"tool-failure"));
        assert!(!collected.contains(&"repo-policy"));
    }

    #[test]
    fn enabling_only_repo_policy_keeps_suite_hooks_off() {
        let flags = RuntimeHookFlags {
            suite_hooks: false,
            repo_policy: true,
        };
        let regs = process_agent_registrations(HookAgent::Claude, flags);
        let collected = names(&regs);
        assert!(collected.contains(&"repo-policy"));
        assert!(!collected.contains(&"guard-stop"));
        assert!(!collected.contains(&"context-agent"));
        assert!(!collected.contains(&"validate-agent"));
        assert!(!collected.contains(&"tool-failure"));
    }

    #[test]
    fn all_enabled_matches_legacy_baseline_for_each_agent() {
        for agent in [
            HookAgent::Claude,
            HookAgent::Codex,
            HookAgent::Gemini,
            HookAgent::Copilot,
            HookAgent::Vibe,
            HookAgent::OpenCode,
        ] {
            let regs = process_agent_registrations(agent, RuntimeHookFlags::all_enabled());
            let collected = names(&regs);
            assert!(
                collected.contains(&"tool-guard"),
                "{agent:?} missing tool-guard"
            );
            assert!(
                collected.contains(&"tool-result"),
                "{agent:?} missing tool-result"
            );
            assert!(
                collected.contains(&"repo-policy"),
                "{agent:?} missing repo-policy"
            );
            assert!(
                collected.contains(&"guard-stop"),
                "{agent:?} missing guard-stop"
            );
            // Gemini does not emit subagent gates in the legacy baseline.
            if !matches!(agent, HookAgent::Gemini | HookAgent::Copilot) {
                assert!(
                    collected.contains(&"context-agent"),
                    "{agent:?} missing context-agent"
                );
                assert!(
                    collected.contains(&"validate-agent"),
                    "{agent:?} missing validate-agent"
                );
            }
        }
    }
}
