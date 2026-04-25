use std::path::Path;

mod wrapped;

use crate::hooks::adapters::{HookAgent, RenderedHookResponse, adapter_for};
use crate::hooks::protocol::context::NormalizedEvent;
use crate::hooks::protocol::result::NormalizedHookResult;
use crate::kernel::command_intent::{ParsedCommand, is_shell_control_op, normalized_binary_name};
use wrapped::{split_env_prefix, wrapped_command, wrapped_command_suggestions};

const SESSION_START_CONTEXT: &str = concat!(
    "Repo policy:\n",
    "- Discover supported workflows with `mise tasks ls`.\n",
    "- Run repo-supported logic only through `mise run <task>` or `mise run <task> -- <args>`.\n",
    "- Run `mise` commands directly. Do not wrap them in `bash -lc`, `zsh -lc`, `rtk env`, `env`, or similar shells/wrappers.\n",
    "- Canonical task families here are `check`, `test`, `check:scripts`, `cargo:local`, \
     `setup:*`, `version:*`, `monitor:macos:*`, `observability:*`, `host-metrics:*`, \
     `mcp:*`, `preview:*`, `check:stale`, and `clean:stale`.\n",
    "- Do not run repo scripts directly. Do not run raw `cargo`, raw `xcodebuild`, or other \
     manual command paths when a `mise` task already covers that workflow.\n",
    "\n",
    "Constraints:\n",
    "- Elevated permissions: every action carries weight; triage before acting.\n",
    "- Read-only system posture outside the working tree: before any local-machine mutation \
     beyond repo files, stop and triage irreversible side effects.\n",
    "- Git history is append-only: only new forward commits. No rebase, amend, reset, \
     force-push, checkout, restore, or stash.\n",
    "- Every commit uses `-sS`. After each commit, verify the signature and that the \
     sign-off is exactly `Bart Smykla <bartek@smykla.com>`.\n",
    "- Before every commit, run the right build gate unless the change is only docs or \
     version-sync noise: Rust -> `mise run check`; Swift -> `mise run monitor:macos:lint` \
     plus the relevant build/test lane from `apps/harness-monitor-macos/CLAUDE.md`; \
     cross-stack -> both gates.\n",
    "- Investigate the real code path before fixing: map call sites, state flow, \
     cross-process boundaries, and existing tests.\n",
    "- Break work into the smallest independently committable chunks. Every chunk must leave \
     the touched stacks buildable and test-passing.\n",
    "- For each chunk: write or tighten the test first and confirm red, implement the fix, \
     confirm green, run the right gate, verify runtime behavior when it matters, commit with \
     `-sS`, verify signature/sign-off, then continue.\n",
    "- After the last chunk, rerun every touched gate and resolve anything still open.\n",
    "- The session is not done until every part of the task is done. Do not stop early.\n",
    "- Use descriptive names, correct comments or none, remove dead code, keep functions under \
     100 lines, and keep important logic near the top of files.\n",
    "- Use native APIs and idiomatic code. Long-term fixes only. Do not suppress, silence, \
     or work around the issue.\n",
    "- Check for performance regressions when touching hot paths, actors, async state \
     machines, concurrency, or shared state.\n",
    "- Parallel agent awareness: if another agent owns a file, switch scope. If blocked for \
     5 minutes, ask the user and wait.\n",
    "- If 1Password is unavailable when commit signing is needed, hard stop and wait. \
     Do not bypass 1Password or use a different key.\n",
);

#[derive(Debug, Clone, PartialEq, Eq)]
struct SuggestedTask {
    replacement: String,
}

pub(crate) fn session_start_context() -> &'static str {
    SESSION_START_CONTEXT
}

pub(crate) fn pre_tool_use_output(
    agent: HookAgent,
    raw_payload: &[u8],
) -> Option<RenderedHookResponse> {
    let Ok(context) = adapter_for(agent).parse_input(raw_payload) else {
        return None;
    };
    if !matches!(context.event, NormalizedEvent::BeforeToolUse) {
        return None;
    }
    let command_text = context
        .tool
        .as_ref()
        .and_then(|tool| tool.input.command_text())?;
    let reason = manual_command_denial_reason(command_text)?;
    let result = NormalizedHookResult::deny("MISE001", reason);
    Some(adapter_for(agent).render_output(&result, &context.event))
}

fn manual_command_denial_reason(command_text: &str) -> Option<String> {
    let trimmed = command_text.trim();
    if trimmed.is_empty() {
        return None;
    }

    let Ok(parsed) = ParsedCommand::parse(trimmed) else {
        return None;
    };
    let suggestions = whole_command_suggestion(parsed.words()).map_or_else(
        || suggested_tasks(parsed.words()),
        |suggestion| vec![suggestion],
    );
    if suggestions.is_empty() {
        return None;
    }

    Some(if suggestions.len() == 1 {
        format!(
            "Repository policy requires `mise` tasks for repo-supported workflows. Do not run `{trimmed}` directly. Run `{}` instead. The current pre-tool hook cannot rewrite the command automatically yet, so rerun it explicitly via `mise`.",
            suggestions[0].replacement
        )
    } else {
        let replacements = suggestions
            .iter()
            .map(|suggestion| format!("- `{}`", suggestion.replacement))
            .collect::<Vec<_>>()
            .join("\n");
        format!(
            "Repository policy requires `mise` tasks for repo-supported workflows. Split this manual shell chain and rerun it with the canonical tasks:\n{replacements}\nThe current pre-tool hook cannot rewrite the command automatically yet."
        )
    })
}

fn suggested_tasks(words: &[String]) -> Vec<SuggestedTask> {
    let mut suggestions = Vec::new();
    for segment in command_segments(words) {
        suggestions.extend(suggestions_for_segment(segment, &[]));
    }
    suggestions
}

fn command_segments(words: &[String]) -> Vec<&[String]> {
    let mut segments = Vec::new();
    let mut start = 0;
    for (index, word) in words.iter().enumerate() {
        if is_shell_control_op(word) {
            if start < index {
                segments.push(&words[start..index]);
            }
            start = index + 1;
        }
    }
    if start < words.len() {
        segments.push(&words[start..]);
    }
    segments
}

fn suggestions_for_segment(
    segment: &[String],
    inherited_env_prefix: &[String],
) -> Vec<SuggestedTask> {
    if segment.is_empty() {
        return Vec::new();
    }

    let (env_prefix, words) = split_env_prefix(segment, inherited_env_prefix);
    if words.is_empty() {
        return Vec::new();
    }

    if let Some((wrapper_env, nested_command)) = wrapped_command(words) {
        let mut merged_env = env_prefix;
        merged_env.extend(wrapper_env);
        return wrapped_command_suggestions(&nested_command, &merged_env);
    }

    let head = normalized_binary_name(&words[0]);
    if head == "mise" {
        return Vec::new();
    }

    let (script_index, args_start) = if is_shell_interpreter(&head) && words.len() >= 2 {
        (1, 2)
    } else {
        (0, 1)
    };
    let Some(script_basename) = file_name(&words[script_index]) else {
        return Vec::new();
    };

    match match script_basename {
        "check-no-stale-state.sh" => exact_task(&env_prefix, "check:stale"),
        "clean-stale-state.sh" => exact_task(&env_prefix, "clean:stale"),
        "check-scripts.sh" => exact_task(&env_prefix, "check:scripts"),
        "cargo-local.sh" => passthrough_task(&env_prefix, "cargo:local", &words[args_start..]),
        "post-generate.sh" => exact_task(&env_prefix, "monitor:macos:generate"),
        "xcodebuild-with-lock.sh" => passthrough_task(
            &env_prefix,
            "monitor:macos:xcodebuild",
            &words[args_start..],
        ),
        "run-quality-gates.sh" => exact_task(&env_prefix, "monitor:macos:lint"),
        "test-swift.sh" => exact_task(&env_prefix, "monitor:macos:test"),
        "test-agents-e2e.sh" => exact_task(&env_prefix, "monitor:macos:test:agents-e2e"),
        "run-instruments-audit.sh" => {
            passthrough_task(&env_prefix, "monitor:macos:audit", &words[args_start..])
        }
        "run-instruments-audit-from-ref.sh" => passthrough_task(
            &env_prefix,
            "monitor:macos:audit:from-ref",
            &words[args_start..],
        ),
        "preview-render.sh" => {
            passthrough_task(&env_prefix, "preview:render", &words[args_start..])
        }
        "preview-smoke.sh" => exact_task(&env_prefix, "preview:smoke"),
        "version.sh" => version_task(&env_prefix, &words[args_start..]),
        "observability.sh" => subcommand_task(
            &env_prefix,
            "observability",
            &words[args_start..],
            Some((
                "--restore-smoke-stack-fixture",
                "restore-smoke-stack-fixture",
            )),
        ),
        "host-metrics.sh" => {
            subcommand_task(&env_prefix, "host-metrics", &words[args_start..], None)
        }
        "mcp-socket-path.sh" => exact_task(&env_prefix, "mcp:socket-path"),
        "mcp-smoke.sh" => passthrough_task(&env_prefix, "mcp:smoke", &words[args_start..]),
        "mcp-doctor.sh" => exact_task(&env_prefix, "mcp:doctor"),
        "mcp-register-claude.sh" => {
            passthrough_task(&env_prefix, "mcp:register-claude", &words[args_start..])
        }
        "mcp-wait-socket.sh" => {
            passthrough_task(&env_prefix, "mcp:wait-socket", &words[args_start..])
        }
        "mcp-launch-monitor.sh" => exact_task(&env_prefix, "mcp:launch:monitor"),
        "mcp-launch-dev.sh" => exact_task(&env_prefix, "mcp:launch:dev"),
        _ => command_head_task(&env_prefix, words, &head),
    } {
        Some(suggestion) => vec![suggestion],
        None => Vec::new(),
    }
}

fn whole_command_suggestion(words: &[String]) -> Option<SuggestedTask> {
    match words {
        [head, stop, op, restart_head, start]
            if same_script(head, restart_head, "observability.sh")
                && stop == "stop"
                && op == "&&"
                && start == "start" =>
        {
            exact_task(&[], "observability:restart")
        }
        [head, stop, op, restart_head, start]
            if same_script(head, restart_head, "host-metrics.sh")
                && stop == "stop"
                && op == "&&"
                && start == "start" =>
        {
            exact_task(&[], "host-metrics:restart")
        }
        _ => None,
    }
}

fn command_head_task(env_prefix: &[String], words: &[String], head: &str) -> Option<SuggestedTask> {
    match head {
        "cargo" => passthrough_task(env_prefix, "cargo:local", &words[1..]),
        "xcodebuild" => passthrough_task(env_prefix, "monitor:macos:xcodebuild", &words[1..]),
        "harness" => harness_task(env_prefix, &words[1..]),
        "python" | "python3" if is_monitor_script_test_command(words) => {
            exact_task(env_prefix, "monitor:macos:test:scripts")
        }
        "swift" if is_mcp_input_helper_build(words) => {
            exact_task(env_prefix, "mcp:build:input-helper")
        }
        _ => None,
    }
}

fn harness_task(env_prefix: &[String], args: &[String]) -> Option<SuggestedTask> {
    match args.first().map(String::as_str) {
        Some("setup") => harness_setup_task(env_prefix, &args[1..]),
        Some("mcp") if args.get(1).is_some_and(|part| part == "serve") => {
            exact_task(env_prefix, "mcp:serve")
        }
        _ => None,
    }
}

fn harness_setup_task(env_prefix: &[String], args: &[String]) -> Option<SuggestedTask> {
    match args {
        [agents, generate] if agents == "agents" && generate == "generate" => {
            exact_task(env_prefix, "setup:agents:generate")
        }
        [agents, generate, check]
            if agents == "agents" && generate == "generate" && check == "--check" =>
        {
            exact_task(env_prefix, "check:agent-assets")
        }
        [agents, generate, rest @ ..] if agents == "agents" && generate == "generate" => {
            passthrough_task(env_prefix, "setup:agents:generate", rest)
        }
        [bootstrap] if bootstrap == "bootstrap" => exact_task(env_prefix, "setup:bootstrap"),
        [bootstrap, rest @ ..] if bootstrap == "bootstrap" => {
            passthrough_task(env_prefix, "setup:bootstrap", rest)
        }
        _ => None,
    }
}

fn version_task(env_prefix: &[String], args: &[String]) -> Option<SuggestedTask> {
    let task = match args.first()?.as_str() {
        "show" => "version:show",
        "set" => "version:set",
        "sync" => "version:sync",
        "sync-monitor" => "version:sync:monitor",
        "check" => "version:check",
        _ => return None,
    };
    passthrough_task(env_prefix, task, &args[1..])
}

fn subcommand_task(
    env_prefix: &[String],
    namespace: &str,
    args: &[String],
    flag_alias: Option<(&str, &str)>,
) -> Option<SuggestedTask> {
    if let Some((flag, alias)) = flag_alias
        && args.first().is_some_and(|arg| arg == flag)
    {
        return exact_task(env_prefix, &format!("{namespace}:{alias}"));
    }
    let subcommand = args.first()?;
    if !matches_known_task(namespace, subcommand) {
        return None;
    }
    exact_task(env_prefix, &format!("{namespace}:{subcommand}"))
}

fn passthrough_task(env_prefix: &[String], task: &str, args: &[String]) -> Option<SuggestedTask> {
    if task.is_empty() {
        return None;
    }
    let env_prefix = render_env_prefix(env_prefix);
    let passthrough = if args.is_empty() {
        String::new()
    } else {
        format!(" -- {}", shell_words::join(args.iter().map(String::as_str)))
    };
    Some(SuggestedTask {
        replacement: format!("{env_prefix}mise run {task}{passthrough}"),
    })
}

fn exact_task(env_prefix: &[String], task: &str) -> Option<SuggestedTask> {
    if task.is_empty() {
        return None;
    }
    Some(SuggestedTask {
        replacement: format!("{}mise run {task}", render_env_prefix(env_prefix)),
    })
}

fn render_env_prefix(env_prefix: &[String]) -> String {
    if env_prefix.is_empty() {
        String::new()
    } else {
        format!(
            "{} ",
            shell_words::join(env_prefix.iter().map(String::as_str))
        )
    }
}

fn same_script(left: &str, right: &str, expected_basename: &str) -> bool {
    file_name(left) == Some(expected_basename) && file_name(right) == Some(expected_basename)
}

fn is_shell_interpreter(head: &str) -> bool {
    matches!(head, "bash" | "fish" | "sh" | "zsh")
}

fn file_name(path: &str) -> Option<&str> {
    Path::new(path).file_name()?.to_str()
}

fn is_monitor_script_test_command(words: &[String]) -> bool {
    words
        .windows(2)
        .any(|window| window[0] == "-s" && window[1] == "apps/harness-monitor-macos/Scripts/tests")
}

fn is_mcp_input_helper_build(words: &[String]) -> bool {
    words.windows(2).any(|window| {
        window[0] == "--package-path" && window[1] == "mcp-servers/harness-monitor-registry"
    }) && words
        .windows(2)
        .any(|window| window[0] == "--product" && window[1] == "harness-monitor-input")
}

fn matches_known_task(namespace: &str, subcommand: &str) -> bool {
    match namespace {
        "observability" => matches!(
            subcommand,
            "start" | "stop" | "restart" | "status" | "logs" | "open" | "reset" | "wipe" | "smoke"
        ),
        "host-metrics" => matches!(
            subcommand,
            "install"
                | "uninstall"
                | "start"
                | "stop"
                | "restart"
                | "status"
                | "metrics"
                | "logs"
                | "build-darwin-exporter"
        ),
        _ => false,
    }
}

#[cfg(test)]
mod tests;
