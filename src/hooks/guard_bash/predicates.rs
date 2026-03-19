use std::collections::BTreeSet;
use std::path::Path;
use std::sync::OnceLock;

use crate::errors::HookMessage;
use crate::hooks::protocol::hook_result::HookResult;
use crate::infra::blocks::BlockRegistry;
use crate::rules::suite_runner::{
    AdminEndpointHint, LegacyScript, PythonBinary, RunnerBinary, TaskOutputPattern,
    TrackedHarnessSubcommand,
};
use crate::kernel::command_intent::{
    contains_subshell_pattern, is_env_assignment, is_shell_control_op, normalized_binary_name,
    semantic_harness_subcommand, semantic_harness_tail, significant_words,
};

fn denied_cluster_binaries() -> &'static BTreeSet<String> {
    static DENIED: OnceLock<BTreeSet<String>> = OnceLock::new();
    DENIED.get_or_init(|| BlockRegistry::production().all_denied_binaries())
}

fn is_denied_cluster_binary(name: &str) -> bool {
    denied_cluster_binaries().contains(name)
}

pub(crate) fn is_run_scope_flag(s: &str) -> bool {
    matches!(s, "--run-dir" | "--run-id" | "--run-root")
        || s.starts_with("--run-dir=")
        || s.starts_with("--run-id=")
        || s.starts_with("--run-root=")
}

pub(crate) fn deny_runner_flow(details: &str) -> HookResult {
    HookMessage::runner_flow_required("run this command", details.to_string()).into_result()
}

pub(crate) fn is_harness_head(heads: &[String]) -> bool {
    !heads.is_empty() && heads.iter().all(|h| h == "harness")
}

pub(crate) fn is_tracked_harness_command(words: &[String]) -> bool {
    let sig = significant_words(words);
    semantic_harness_subcommand(&sig).is_some_and(TrackedHarnessSubcommand::is_tracked)
}

pub(crate) fn has_denied_cluster_binary(heads: &[String]) -> bool {
    heads.iter().any(|h| is_denied_cluster_binary(h))
}

pub(crate) fn has_denied_cluster_binary_anywhere(words: &[String]) -> bool {
    words
        .iter()
        .any(|w| is_denied_cluster_binary(&normalized_binary_name(w)))
}

pub(crate) fn has_denied_runner_binary(heads: &[String]) -> bool {
    heads.iter().any(|h| RunnerBinary::is_denied(h))
}

pub(crate) fn has_task_output_access(words: &[String], command_text: Option<&str>) -> bool {
    let command = command_text.unwrap_or("");
    if TaskOutputPattern::matches_any(command) {
        return true;
    }
    words.iter().any(|w| TaskOutputPattern::matches_any(w))
}

pub(crate) fn has_admin_endpoint_hint(words: &[String]) -> bool {
    words.iter().any(|w| AdminEndpointHint::contains_hint(w))
}

pub(crate) fn has_python_inline(words: &[String]) -> bool {
    for (i, word) in words.iter().enumerate() {
        let name = normalized_binary_name(word);
        if !PythonBinary::is_python(&name) {
            continue;
        }
        if i + 1 < words.len() && matches!(words[i + 1].as_str(), "-c" | "-") {
            return true;
        }
    }
    false
}

pub(crate) fn deny_python() -> HookResult {
    HookMessage::approval_required(
        "use python",
        "do not use python for JSON parsing; \
         use jq for JSON filtering or harness run envoy capture for Envoy admin data",
    )
    .into_result()
}

pub(crate) fn has_denied_legacy_script(words: &[String]) -> bool {
    words.iter().any(|w| {
        let name = Path::new(w)
            .file_name()
            .map_or("", |n| n.to_str().unwrap_or(""));
        LegacyScript::is_denied(name)
    })
}

pub(crate) fn make_target(words: &[String]) -> Option<&str> {
    let mut seen_make = false;
    for word in words {
        let name = Path::new(word)
            .file_name()
            .map_or("", |n| n.to_str().unwrap_or(""));
        if name == "make" {
            seen_make = true;
            continue;
        }
        if !seen_make || word.starts_with('-') || word.contains('=') {
            continue;
        }
        return Some(word);
    }
    None
}

pub(crate) fn allows_wrapped_envoy_admin(words: &[String]) -> bool {
    let sig: Vec<&str> = words
        .iter()
        .filter(|w| !is_shell_control_op(w) && !is_env_assignment(w))
        .map(String::as_str)
        .collect();
    let Some(tail) = semantic_harness_tail(&sig) else {
        return false;
    };
    semantic_harness_subcommand(&sig) == Some("record")
        || (tail.len() >= 2 && tail[0] == "envoy" && tail[1] == "capture")
}

/// Scan raw command text for subshell substitution patterns that contain
/// denied cluster binaries. This catches smuggling attempts that bypass
/// token-level binary name checks.
pub(crate) fn has_denied_subshell_binary(command_text: Option<&str>, words: &[String]) -> bool {
    let text = command_text.unwrap_or("");

    // Fast path: no subshell syntax at all
    if !contains_subshell_pattern(text) && !words.iter().any(|w| contains_subshell_pattern(w)) {
        return false;
    }

    // Check every token for subshell-wrapped denied binaries
    for word in words {
        let normalized = normalized_binary_name(word);
        if is_denied_cluster_binary(&normalized) {
            return true;
        }
    }

    // Also scan the raw text for denied binary names inside $(...) or backticks.
    // This catches cases where shell_words splits tokens in ways that hide
    // the binary name from individual token normalization.
    for name in denied_cluster_binaries() {
        if text.contains(&format!("$({name}"))
            || text.contains(&format!("`{name}"))
            || text.contains(&format!("`{name}`"))
        {
            return true;
        }
    }

    false
}
