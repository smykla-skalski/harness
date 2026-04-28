use std::path::Path;

use crate::command_intent::{
    is_shell_control_op, normalized_binary_name, parse_supported_command_text,
};
use crate::hook_agent::HookAgent;
use crate::hook_payload::HookEvent;
use crate::hook_render::{HookResult, RenderedHookResponse, render_pre_tool_use_output};
use crate::policy_spec::{
    BINARY_POLICIES, EXACT_CHAIN_POLICIES, HARNESS_ROUTES, NAMESPACE_POLICIES, SCRIPT_POLICIES,
    SESSION_START_CONTEXT, VERSION_ROUTES, WordRoute,
};

mod wrapped;

use wrapped::{split_env_prefix, wrapped_command};

#[derive(Debug, Clone, PartialEq, Eq)]
struct SuggestedTask {
    replacement: String,
}

pub fn session_start_context() -> &'static str {
    SESSION_START_CONTEXT.as_str()
}

pub fn pre_tool_use_output(
    agent: HookAgent,
    raw_payload: &[u8],
) -> Result<RenderedHookResponse, String> {
    let payload = crate::hook_payload::parse_hook_payload(agent, raw_payload)?;
    if payload.event != HookEvent::BeforeToolUse {
        return Err(format!(
            "unsupported hook event for repo-policy: {}",
            payload.event
        ));
    }
    let command_text = payload.command_text.as_deref().ok_or_else(|| {
        "invalid hook payload: repo-policy expected a shell command in tool_input.command"
            .to_string()
    })?;
    let Some(reason) = manual_command_denial_reason(command_text)? else {
        return Ok(RenderedHookResponse::allow());
    };
    let result = HookResult::deny("MISE001", reason);
    Ok(render_pre_tool_use_output(agent, &result))
}

pub fn manual_command_denial_reason(command_text: &str) -> Result<Option<String>, String> {
    let trimmed = command_text.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }

    // Top-level command text uses the same narrow grammar as wrapped commands:
    // shell control operators must already be standalone tokens. Shapes like
    // `cargo test&&cargo check` are rejected explicitly instead of guessed.
    let parsed = parse_supported_command_text(trimmed, "top-level")?;
    let suggestions = whole_command_suggestion(parsed.words()).map_or_else(
        || suggested_tasks(parsed.words()),
        |suggestion| Ok(vec![suggestion]),
    )?;
    if suggestions.is_empty() {
        return Ok(None);
    }

    Ok(Some(if suggestions.len() == 1 {
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
    }))
}

fn suggested_tasks(words: &[String]) -> Result<Vec<SuggestedTask>, String> {
    let mut suggestions = Vec::new();
    for segment in command_segments(words) {
        suggestions.extend(suggestions_for_segment(segment, &[])?);
    }
    Ok(suggestions)
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
) -> Result<Vec<SuggestedTask>, String> {
    if segment.is_empty() {
        return Ok(Vec::new());
    }

    let (env_prefix, words) = split_env_prefix(segment, inherited_env_prefix);
    if words.is_empty() {
        return Ok(Vec::new());
    }

    if let Some((wrapper_env, wrapped_words)) = wrapped_command(words)? {
        let mut merged_env = env_prefix;
        merged_env.extend(wrapper_env);
        return suggestions_for_wrapped_words(wrapped_words.words(), &merged_env);
    }

    let head = normalized_binary_name(&words[0]);
    if head == "mise" {
        return Ok(Vec::new());
    }

    let (script_index, args_start) = if is_shell_interpreter(&head) && words.len() >= 2 {
        (1, 2)
    } else {
        (0, 1)
    };
    let suggestion = file_name(&words[script_index]).and_then(|script_basename| {
        script_task(&env_prefix, script_basename, &words[args_start..])
            .or_else(|| command_head_task(&env_prefix, words, &head))
    });

    Ok(match suggestion {
        Some(suggestion) => vec![suggestion],
        None => Vec::new(),
    })
}

fn whole_command_suggestion(words: &[String]) -> Option<SuggestedTask> {
    if let [left, lhs_arg, operator, right, rhs_arg] = words {
        let left_basename = file_name(left)?;
        let right_basename = file_name(right)?;
        let policy = EXACT_CHAIN_POLICIES.iter().find(|policy| {
            left_basename == policy.command_basename
                && right_basename == policy.command_basename
                && lhs_arg == policy.lhs_arg
                && operator == policy.operator
                && rhs_arg == policy.rhs_arg
        })?;
        return exact_task(&[], policy.task);
    }
    None
}

fn suggestions_for_wrapped_words(
    words: &[String],
    env_prefix: &[String],
) -> Result<Vec<SuggestedTask>, String> {
    if let Some(suggestion) = whole_command_suggestion(words) {
        return Ok(vec![prefix_suggestion(env_prefix, suggestion)]);
    }

    let direct_mise = direct_mise_suggestions(words, env_prefix);
    if !direct_mise.is_empty() {
        return Ok(direct_mise);
    }

    let mut suggestions = Vec::new();
    for segment in command_segments(words) {
        suggestions.extend(suggestions_for_segment(segment, env_prefix)?);
    }
    Ok(suggestions)
}

fn direct_mise_suggestions(words: &[String], env_prefix: &[String]) -> Vec<SuggestedTask> {
    let mut suggestions = Vec::new();
    for segment in command_segments(words) {
        if let Some(suggestion) = direct_mise_suggestion_for_segment(segment, env_prefix) {
            suggestions.push(suggestion);
        }
    }
    suggestions
}

fn direct_mise_suggestion_for_segment(
    segment: &[String],
    env_prefix: &[String],
) -> Option<SuggestedTask> {
    let (nested_env_prefix, nested_words) = split_env_prefix(segment, env_prefix);
    (normalized_binary_name(nested_words.first()?) == "mise").then(|| SuggestedTask {
        replacement: format!(
            "{}{}",
            render_env_prefix(&nested_env_prefix),
            shell_words::join(nested_words.iter().map(String::as_str))
        ),
    })
}

fn prefix_suggestion(env_prefix: &[String], suggestion: SuggestedTask) -> SuggestedTask {
    if env_prefix.is_empty() {
        return suggestion;
    }
    SuggestedTask {
        replacement: format!(
            "{}{}",
            render_env_prefix(env_prefix),
            suggestion.replacement
        ),
    }
}

fn command_head_task(env_prefix: &[String], words: &[String], head: &str) -> Option<SuggestedTask> {
    if let Some(policy) = BINARY_POLICIES.iter().find(|policy| policy.binary == head) {
        return if policy.passthrough_args {
            passthrough_task(env_prefix, policy.task, &words[1..])
        } else {
            exact_task(env_prefix, policy.task)
        };
    }

    match head {
        "harness" => harness_task(env_prefix, &words[1..]),
        // These remain code because the routing depends on flag presence rather
        // than a stable prefix table. Keep them narrow and test-backed.
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
    route_task(env_prefix, args, HARNESS_ROUTES)
}

fn script_task(env_prefix: &[String], basename: &str, args: &[String]) -> Option<SuggestedTask> {
    if let Some(policy) = SCRIPT_POLICIES
        .iter()
        .find(|policy| policy.basename == basename)
    {
        return if policy.passthrough_args {
            passthrough_task(env_prefix, policy.task, args)
        } else {
            exact_task(env_prefix, policy.task)
        };
    }

    match basename {
        "version.sh" => route_task(env_prefix, args, VERSION_ROUTES),
        "observability.sh" => namespace_task(env_prefix, "observability", args),
        "host-metrics.sh" => namespace_task(env_prefix, "host-metrics", args),
        _ => None,
    }
}

fn namespace_task(
    env_prefix: &[String],
    namespace: &str,
    args: &[String],
) -> Option<SuggestedTask> {
    let policy = NAMESPACE_POLICIES
        .iter()
        .find(|policy| policy.namespace == namespace)?;
    if let Some(alias) = policy
        .flag_aliases
        .iter()
        .find(|alias| args.first().is_some_and(|arg| arg == alias.flag))
    {
        return exact_task(env_prefix, &format!("{namespace}:{}", alias.alias));
    }
    let subcommand = args.first()?;
    policy
        .subcommands
        .contains(&subcommand.as_str())
        .then(|| exact_task(env_prefix, &format!("{namespace}:{subcommand}")))
        .flatten()
}

fn route_task(
    env_prefix: &[String],
    args: &[String],
    routes: &[WordRoute],
) -> Option<SuggestedTask> {
    let route = routes
        .iter()
        .filter(|route| route_matches(args, route.path))
        .max_by_key(|route| route.path.len())?;

    match route.passthrough_start {
        Some(start) => passthrough_task(env_prefix, route.task, &args[start..]),
        None => exact_task(env_prefix, route.task),
    }
}

fn route_matches(args: &[String], path: &[&str]) -> bool {
    args.len() >= path.len()
        && args
            .iter()
            .zip(path.iter())
            .all(|(arg, expected)| arg == expected)
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
            env_prefix
                .iter()
                .map(|word| render_shell_word(word))
                .collect::<Vec<_>>()
                .join(" ")
        )
    }
}

fn render_shell_word(word: &str) -> String {
    if is_plain_env_assignment(word) {
        word.to_string()
    } else {
        shell_words::join([word])
    }
}

fn is_plain_env_assignment(word: &str) -> bool {
    crate::command_intent::is_env_assignment(word)
        && !word.chars().any(|character| character.is_whitespace())
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

#[cfg(test)]
mod tests {
    use super::{manual_command_denial_reason, session_start_context};
    use crate::policy_spec::{ENFORCEMENT_EXAMPLES, TASK_FAMILY_SPECS};

    #[test]
    fn session_start_context_lists_all_canonical_task_families() {
        let context = session_start_context();
        for family in TASK_FAMILY_SPECS {
            assert!(
                context.contains(family.name),
                "missing task family {}",
                family.name
            );
        }
    }

    #[test]
    fn enforcement_examples_match_current_policy_spec() {
        for example in ENFORCEMENT_EXAMPLES {
            let reason = manual_command_denial_reason(example.command)
                .expect("example command should parse")
                .expect("example command should be blocked");
            assert!(
                reason.contains(example.replacement),
                "expected replacement {} for command {}",
                example.replacement,
                example.command
            );
        }
    }
}
