use std::collections::BTreeSet;
use std::sync::OnceLock;

use crate::hooks::protocol::hook_result::HookResult;
use crate::hooks::runner_policy::managed_cluster_binaries;
use crate::hooks::runner_policy::{AdminEndpointHint, PythonBinary, SuiteMutationBinary};
use harness_kernel::errors::HookMessage;
use harness_kernel::kernel::command_intent::{
    command_heads, contains_subshell_pattern, normalized_binary_name, path_like_words,
};

fn denied_cluster_binaries() -> &'static BTreeSet<String> {
    static DENIED: OnceLock<BTreeSet<String>> = OnceLock::new();
    DENIED.get_or_init(managed_cluster_binaries)
}

fn is_denied_cluster_binary(name: &str) -> bool {
    denied_cluster_binaries().contains(name)
}

pub(crate) fn is_harness_head(heads: &[String]) -> bool {
    !heads.is_empty() && heads.iter().all(|h| h == "harness")
}

pub(crate) fn has_denied_cluster_binary(heads: &[String]) -> bool {
    heads.iter().any(|h| is_denied_cluster_binary(h))
}

pub(crate) fn has_denied_cluster_binary_anywhere(words: &[String]) -> bool {
    words
        .iter()
        .any(|w| is_denied_cluster_binary(&normalized_binary_name(w)))
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

pub(crate) fn deny_create_suite_storage_mutation(words: &[String]) -> HookResult {
    let heads = command_heads(words);
    if !heads
        .iter()
        .any(|h| SuiteMutationBinary::is_mutation_binary(&normalized_binary_name(h)))
    {
        return HookResult::allow();
    }
    let path_words = path_like_words(words);
    for word in &path_words {
        if word.contains("/suites/") || word.starts_with("suites/") {
            return HookMessage::approval_required(
                "mutate suite storage",
                "do not delete or overwrite existing suite directories; \
                 use `harness create begin` which handles conflicts",
            )
            .into_result();
        }
    }
    HookResult::allow()
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
