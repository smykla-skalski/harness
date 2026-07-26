use crate::hooks::adapters::{HookAgent, HookRegistration, adapter_for};
use crate::hooks::protocol::context::NormalizedEvent;

pub(crate) fn process_agent_registrations(agent: HookAgent) -> Vec<HookRegistration> {
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
        hook_registration(
            agent,
            "tool-guard",
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ),
        hook_registration(
            agent,
            "tool-result",
            NormalizedEvent::AfterToolUse,
            Some(".*"),
        ),
    ]
}

fn claude_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    vec![
        hook_registration(
            agent,
            "tool-guard",
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ),
        hook_registration(
            agent,
            "tool-result",
            NormalizedEvent::AfterToolUse,
            Some(".*"),
        ),
    ]
}

fn gemini_hooks(agent: HookAgent) -> Vec<HookRegistration> {
    vec![
        hook_registration(
            agent,
            "tool-guard",
            NormalizedEvent::BeforeToolUse,
            Some(".*"),
        ),
        hook_registration(
            agent,
            "tool-result",
            NormalizedEvent::AfterToolUse,
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
        hook_registration(agent, "tool-guard", NormalizedEvent::BeforeToolUse, None),
        hook_registration(agent, "tool-result", NormalizedEvent::AfterToolUse, None),
    ]
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
            format!("harness-hook {subcommand} --agent {agent_name} --project-dir {project_dir}")
        }
        _ => format!("harness-hook {subcommand} --project-dir {project_dir}"),
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
            "harness-hook {name} --agent {} --skill suite:run",
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

    fn assert_contains_all(collected: &[&str], expected: &[&str]) {
        for name in expected {
            assert!(collected.contains(name), "missing hook {name}");
        }
    }

    fn assert_contains_none(collected: &[&str], forbidden: &[&str]) {
        for name in forbidden {
            assert!(!collected.contains(name), "unexpected hook {name}");
        }
    }

    #[test]
    fn suite_lifecycle_hooks_are_never_registered() {
        for agent in [
            HookAgent::Claude,
            HookAgent::Codex,
            HookAgent::Gemini,
            HookAgent::Copilot,
            HookAgent::Vibe,
            HookAgent::OpenCode,
        ] {
            let collected = names(&process_agent_registrations(agent));
            assert_contains_none(
                &collected,
                &[
                    "guard-stop",
                    "context-agent",
                    "validate-agent",
                    "tool-failure",
                ],
            );
            assert_contains_all(&collected, &["tool-guard", "tool-result"]);
        }
    }
}
