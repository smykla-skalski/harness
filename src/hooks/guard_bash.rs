use std::path::Path;

use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner as rules;

/// Shell control operators that separate command pipelines.
const SHELL_CONTROL_OPS: &[&str] = &["&&", "||", ";", "|", "&"];

/// Execute the guard-bash hook.
///
/// Checks whether a Bash command is allowed for the active skill.
/// Denies direct cluster binary usage, admin endpoint access, denied
/// legacy scripts, and denied make targets. Runner phase guards and
/// batched-command checks require workflow state and are deferred.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    let words = ctx.command_words();
    if words.is_empty() {
        return Ok(HookResult::allow());
    }
    let heads = command_heads(&words);
    if ctx.skill == "suite-author" {
        return guard_suite_author(ctx, &words, &heads);
    }
    guard_suite_runner(ctx, &words, &heads)
}

fn guard_suite_author(
    _ctx: &HookContext,
    words: &[String],
    heads: &[String],
) -> Result<HookResult, CliError> {
    if has_denied_cluster_binary(heads) {
        return Ok(errors::hook_msg(&errors::DENY_CLUSTER_BINARY, &[]));
    }
    if !is_harness_head(heads) && has_admin_endpoint_hint(words) {
        return Ok(errors::hook_msg(&errors::DENY_ADMIN_ENDPOINT, &[]));
    }
    Ok(HookResult::allow())
}

fn guard_suite_runner(
    _ctx: &HookContext,
    words: &[String],
    heads: &[String],
) -> Result<HookResult, CliError> {
    // Runner phase guard needs workflow state - deferred.
    if has_denied_runner_binary(heads) {
        return Ok(deny_runner_flow(
            "suite runs must stay on the tracked run; \
             do not switch into CI or GitHub workflows",
        ));
    }
    if let Some(target) = make_target(words)
        && rules::DENIED_MAKE_TARGET_PREFIXES
            .iter()
            .any(|pfx| target.starts_with(pfx))
    {
        return Ok(errors::hook_msg(&errors::DENY_CLUSTER_BINARY, &[]));
    }
    if has_denied_legacy_script(words) {
        return Ok(errors::hook_msg(&errors::DENY_CLUSTER_BINARY, &[]));
    }
    if has_denied_cluster_binary(heads) {
        return Ok(errors::hook_msg(&errors::DENY_CLUSTER_BINARY, &[]));
    }
    if has_admin_endpoint_hint(words) {
        if is_harness_head(heads) || allows_wrapped_envoy_admin(words) {
            return Ok(HookResult::allow());
        }
        return Ok(errors::hook_msg(&errors::DENY_ADMIN_ENDPOINT, &[]));
    }
    Ok(HookResult::allow())
}

fn deny_runner_flow(details: &str) -> HookResult {
    errors::hook_msg(
        &errors::DENY_RUNNER_FLOW_REQUIRED,
        &[("action", "run this command"), ("details", details)],
    )
}

/// Extract the "head" binary of each pipeline segment.
fn command_heads(words: &[String]) -> Vec<String> {
    let mut heads = Vec::new();
    let mut expect = true;
    for word in words {
        if SHELL_CONTROL_OPS.contains(&word.as_str()) {
            expect = true;
            continue;
        }
        if expect && is_env_assignment(word) {
            continue;
        }
        if expect {
            heads.push(normalized_binary_name(word));
            expect = false;
        }
    }
    heads
}

fn normalized_binary_name(raw: &str) -> String {
    let mut s = raw.trim().to_string();
    if s.starts_with("${") && s.ends_with('}') {
        s = s[2..s.len() - 1].to_string();
    } else if let Some(stripped) = s.strip_prefix('$') {
        s = stripped.to_string();
    }
    Path::new(&s)
        .file_name()
        .map_or_else(|| s.to_lowercase(), |n| n.to_string_lossy().to_lowercase())
}

fn is_env_assignment(word: &str) -> bool {
    if let Some(eq_pos) = word.find('=') {
        if eq_pos == 0 {
            return false;
        }
        let prefix = &word[..eq_pos];
        prefix
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_')
            && prefix
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
    } else {
        false
    }
}

fn is_harness_head(heads: &[String]) -> bool {
    !heads.is_empty() && heads.iter().all(|h| h == "harness")
}

fn has_denied_cluster_binary(heads: &[String]) -> bool {
    heads
        .iter()
        .any(|h| rules::DENIED_CLUSTER_BINARIES.contains(&h.as_str()))
}

fn has_denied_runner_binary(heads: &[String]) -> bool {
    heads
        .iter()
        .any(|h| rules::DENIED_RUNNER_BINARIES.contains(&h.as_str()))
}

fn has_admin_endpoint_hint(words: &[String]) -> bool {
    words.iter().any(|w| {
        rules::DENIED_ADMIN_ENDPOINT_HINTS
            .iter()
            .any(|hint| w.contains(hint))
    })
}

fn has_denied_legacy_script(words: &[String]) -> bool {
    words.iter().any(|w| {
        let name = Path::new(w)
            .file_name()
            .map_or("", |n| n.to_str().unwrap_or(""));
        rules::DENIED_LEGACY_SCRIPT_NAMES.contains(&name)
    })
}

fn make_target(words: &[String]) -> Option<String> {
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
        return Some(word.clone());
    }
    None
}

fn allows_wrapped_envoy_admin(words: &[String]) -> bool {
    let sig: Vec<&str> = words
        .iter()
        .filter(|w| !SHELL_CONTROL_OPS.contains(&w.as_str()) && !is_env_assignment(w))
        .map(String::as_str)
        .collect();
    if sig.len() < 2 {
        return false;
    }
    let head = Path::new(sig[0])
        .file_name()
        .map_or("", |n| n.to_str().unwrap_or(""));
    if head != "harness" {
        return false;
    }
    sig[1] == "run"
        || sig[1] == "record"
        || (sig.len() >= 3 && sig[1] == "envoy" && sig[2] == "capture")
}
