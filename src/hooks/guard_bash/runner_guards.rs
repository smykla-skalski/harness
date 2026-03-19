use std::path::Path;

use crate::errors::HookMessage;
use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use crate::hooks::runner_policy::{
    ControlFileMutationBinary, ControlFileReadBinary, MakeTargetPrefix, ScriptInterpreter,
    SuiteMutationBinary, TaskOutputPattern, TrackedHarnessSubcommand,
};
use crate::kernel::command_intent::{
    command_heads, is_shell_chain_op, is_shell_flow_word, is_shell_redirect_op,
    normalized_binary_name, path_like_words, semantic_harness_subcommand, semantic_harness_tail,
    significant_words,
};
use crate::kernel::run_surface::RunFile;
use crate::run::workflow::{RunnerPhase, RunnerWorkflowState};

use super::predicates::{
    allows_wrapped_envoy_admin, deny_python, deny_runner_flow, has_admin_endpoint_hint,
    has_denied_cluster_binary, has_denied_cluster_binary_anywhere, has_denied_legacy_script,
    has_denied_runner_binary, has_python_inline, has_task_output_access, is_harness_head,
    is_run_scope_flag, is_tracked_harness_command, make_target,
};

pub(crate) fn guard_runner_phase(ctx: &HookContext, words: &[String]) -> HookResult {
    if let Some(ref run) = ctx.run
        && let Some(reason) = completed_run_reuse_reason(words)
        && let Some(ref status) = run.status
        && status.overall_verdict.is_finalized()
    {
        return deny_runner_flow(&format!(
            "{reason}. Start a new run with \
             `harness run init --run-id <new-run-id> ...` first"
        ));
    }
    if let Some(ref state) = ctx.runner_state {
        let (allowed, reason) = allowed_command(state, words);
        if !allowed {
            return deny_runner_flow(reason.unwrap_or("runner state does not allow this command"));
        }
    }
    HookResult::allow()
}

fn completed_run_reuse_reason(words: &[String]) -> Option<&'static str> {
    if has_explicit_run_scope(words) {
        return None;
    }
    let sig = significant_words(words);
    let semantic = semantic_harness_tail(&sig)?;
    let subcommand = semantic_harness_subcommand(&sig)?;
    completed_run_reuse_for_subcommand(subcommand, semantic)
}

fn completed_run_reuse_for_subcommand(
    subcommand: &str,
    significant: &[&str],
) -> Option<&'static str> {
    match subcommand {
        "cluster" if cluster_mode_is_teardown(significant) => None,
        "cluster" => Some(
            "the active run is already final; do not start or \
             redeploy clusters on it",
        ),
        "report" if significant.len() >= 2 && significant[1] == "check" => None,
        "report" => Some("the active run is already final; do not mutate the finalized report"),
        "runner-state"
            if significant
                .iter()
                .any(|w| *w == "--event" || w.starts_with("--event=")) =>
        {
            Some("the active run is already final; do not reopen or advance it")
        }
        "apply" | "bootstrap" | "capture" | "cli" | "diff" | "envoy" | "gateway" | "preflight"
        | "record" | "run" | "validate" => Some(
            "the active run is already final; start a new run before \
             continuing bootstrap or execution",
        ),
        _ => None,
    }
}

fn cluster_mode_is_teardown(significant: &[&str]) -> bool {
    significant
        .get(1)
        .is_some_and(|mode| mode.ends_with("-down"))
}

fn has_explicit_run_scope(words: &[String]) -> bool {
    let sig = significant_words(words);
    sig.iter().any(|w| is_run_scope_flag(w))
}

fn allowed_command(state: &RunnerWorkflowState, words: &[String]) -> (bool, Option<&'static str>) {
    let sig = significant_words(words);
    let Some(sub) = semantic_harness_subcommand(&sig) else {
        return (true, None);
    };
    match state.phase() {
        RunnerPhase::Completed | RunnerPhase::Aborted => match sub {
            "closeout" | "runner-state" | "report" | "session-stop" => (true, None),
            _ => (
                false,
                Some("the run has reached a final state; only closeout commands are allowed"),
            ),
        },
        RunnerPhase::Triage => {
            if matches!(sub, "runner-state" | "report" | "closeout") {
                return (true, None);
            }
            if state.suite_fix().is_some() {
                return (true, None);
            }
            (true, None)
        }
        _ => (true, None),
    }
}

pub(crate) fn deny_batched_tracked_harness_commands(words: &[String]) -> HookResult {
    let tracked = tracked_harness_subcommands(words);
    if tracked.is_empty() {
        return HookResult::allow();
    }
    if tracked.len() > 1 {
        return deny_runner_flow(
            "run one tracked `harness` command per Bash tool call; \
             do not batch multiple tracked harness steps together",
        );
    }
    if words
        .iter()
        .any(|w| is_shell_chain_op(w) || is_shell_flow_word(w))
    {
        return deny_runner_flow(&format!(
            "do not wrap tracked `harness {}` commands in shell chains or loops; \
             run the tracked harness step directly",
            tracked[0]
        ));
    }
    HookResult::allow()
}

fn tracked_harness_subcommands(words: &[String]) -> Vec<String> {
    let sig = significant_words(words);
    let mut subs = Vec::new();
    for (i, word) in sig.iter().enumerate() {
        let name = Path::new(word)
            .file_name()
            .map_or("", |n| n.to_str().unwrap_or(""));
        if name != "harness" {
            continue;
        }
        if let Some(sub) = semantic_harness_subcommand(&sig[i..])
            && TrackedHarnessSubcommand::is_tracked(sub)
        {
            subs.push(sub.to_string());
        }
    }
    subs
}

pub(crate) fn deny_harness_managed_run_control_mutation(
    ctx: &HookContext,
    words: &[String],
) -> HookResult {
    let mentioned = run_control_files_mentioned(words, ctx.command_text());
    if mentioned.is_empty() {
        return HookResult::allow();
    }
    let heads: Vec<String> = command_heads(words)
        .into_iter()
        .map(|h| normalized_binary_name(&h))
        .collect();
    if heads.iter().any(|h| ScriptInterpreter::is_interpreter(h)) {
        return deny_runner_flow(&format!(
            "do not use raw interpreters for run control files; {}",
            RunFile::CONTROL_HINT
        ));
    }
    for (i, word) in words.iter().enumerate() {
        if i + 1 >= words.len() {
            break;
        }
        if is_shell_redirect_op(word) {
            let target = &words[i + 1];
            if RunFile::ALL
                .iter()
                .filter(|f| f.is_harness_managed())
                .any(|f| target.contains(&f.to_string()))
            {
                return deny_runner_flow(&format!(
                    "do not redirect shell output into harness-managed run control files; {}",
                    RunFile::CONTROL_HINT
                ));
            }
        }
    }
    if heads
        .iter()
        .any(|h| ControlFileMutationBinary::is_mutation_binary(h))
    {
        return deny_runner_flow(&format!(
            "do not mutate harness-managed run control files directly; {}",
            RunFile::CONTROL_HINT
        ));
    }
    if heads
        .iter()
        .any(|h| ControlFileReadBinary::is_read_binary(h))
    {
        return deny_runner_flow(&format!(
            "do not inspect harness-managed run control files directly; {}",
            RunFile::CONTROL_HINT
        ));
    }
    HookResult::allow()
}

fn run_control_files_mentioned(words: &[String], command_text: Option<&str>) -> Vec<String> {
    let cmd_text = command_text.unwrap_or("");
    RunFile::ALL
        .iter()
        .filter(|f| f.is_harness_managed())
        .map(ToString::to_string)
        .filter(|name| {
            words.iter().any(|w| w.contains(name.as_str())) || cmd_text.contains(name.as_str())
        })
        .collect()
}

pub(crate) fn deny_direct_command_log_access(ctx: &HookContext, words: &[String]) -> HookResult {
    let cmd_text = ctx.command_text().unwrap_or("");
    let refs = ["commands/command-log.md", "command-log.md"];
    let mentioned = words.iter().any(|w| refs.iter().any(|r| w.contains(r)))
        || refs.iter().any(|r| cmd_text.contains(r));
    if !mentioned {
        return HookResult::allow();
    }
    deny_runner_flow(&format!(
        "do not inspect or mutate command-owned run logs directly; {}",
        RunFile::COMMAND_LOG_HINT
    ))
}

pub(crate) fn deny_raw_manifest_write(words: &[String], command_text: Option<&str>) -> HookResult {
    let cmd_text = command_text.unwrap_or("");
    let hints = ["/manifests/", "manifests/"];
    let any_mention = words.iter().any(|w| hints.iter().any(|h| w.contains(h)))
        || hints.iter().any(|h| cmd_text.contains(h));
    if !any_mention {
        return HookResult::allow();
    }
    for (i, word) in words.iter().enumerate() {
        if i + 1 >= words.len() {
            break;
        }
        if is_shell_redirect_op(word) {
            let target = &words[i + 1];
            if hints.iter().any(|h| target.contains(h)) {
                return deny_runner_flow(
                    "do not write manifests via shell redirects; \
                     use `harness apply --manifest <file>` to ensure validation and tracking",
                );
            }
        }
    }
    HookResult::allow()
}

pub(crate) fn deny_suite_storage_mutation(words: &[String]) -> HookResult {
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
            return deny_runner_flow(
                "do not create or mutate suite storage from suite:run; \
                 use an existing suite path",
            );
        }
    }
    HookResult::allow()
}

const DELETE_FLAGS_WITH_VALUE: &[&str] = &[
    "-n",
    "--namespace",
    "-l",
    "--selector",
    "-o",
    "--output",
    "--cascade",
    "--context",
    "--cluster",
    "--field-selector",
    "--grace-period",
    "--kubeconfig",
    "--timeout",
    "--wait",
];

const KUMA_DELETE_RESOURCE_KINDS: &[&str] = &[
    "meshopentelemetrybackend",
    "meshopentelemetrybackends",
    "meshmetric",
    "meshmetrics",
    "meshtrace",
    "meshtraces",
    "meshaccesslog",
    "meshaccesslogs",
];

pub(crate) fn deny_mixed_kuma_delete(words: &[String]) -> HookResult {
    let Some(dw) = tracked_kubectl_delete_words(words) else {
        return HookResult::allow();
    };
    if dw
        .iter()
        .any(|w| *w == "-f" || *w == "--filename" || w.starts_with("--filename="))
    {
        return HookResult::allow();
    }
    let mut positional = Vec::new();
    let mut skip_next = false;
    for word in &dw {
        if skip_next {
            skip_next = false;
            continue;
        }
        if DELETE_FLAGS_WITH_VALUE.contains(&word.as_str()) {
            skip_next = true;
            continue;
        }
        if word.starts_with('-') {
            continue;
        }
        positional.push(word.as_str());
    }
    let kinds: Vec<&str> = positional
        .iter()
        .filter(|w| KUMA_DELETE_RESOURCE_KINDS.contains(w))
        .copied()
        .collect();
    let mut unique_kinds: Vec<&str> = kinds;
    unique_kinds.sort_unstable();
    unique_kinds.dedup();
    if unique_kinds.len() < 2 {
        return HookResult::allow();
    }
    deny_runner_flow(
        "cleanup must not mix multiple resource kinds in one tracked `kubectl delete`; \
         use `kubectl delete -f` or one recorded delete per resource kind",
    )
}

fn tracked_kubectl_delete_words(words: &[String]) -> Option<Vec<String>> {
    let sig = significant_words(words);
    let semantic = semantic_harness_tail(&sig)?;
    if semantic_harness_subcommand(&sig) != Some("record") {
        return None;
    }
    for (i, word) in semantic.iter().enumerate() {
        let name = Path::new(word)
            .file_name()
            .map_or("", |n| n.to_str().unwrap_or(""));
        if name == "kubectl" && i + 1 < semantic.len() && semantic[i + 1] == "delete" {
            return Some(
                semantic[i + 2..]
                    .iter()
                    .map(|word| (*word).to_string())
                    .collect(),
            );
        }
    }
    None
}

pub(crate) fn deny_author_suite_storage_mutation(words: &[String]) -> HookResult {
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
                 use `harness authoring begin` which handles conflicts",
            )
            .into_result();
        }
    }
    HookResult::allow()
}

#[must_use]
pub(crate) fn has_tracked_run_context(ctx: &HookContext) -> bool {
    ctx.run.is_some() || ctx.runner_state.is_some() || ctx.effective_run_dir().is_some()
}

pub(crate) fn runner_binary_and_pattern_guards(
    ctx: &HookContext,
    words: &[String],
    heads: &[String],
) -> Option<HookResult> {
    if has_task_output_access(words, ctx.command_text()) {
        return Some(deny_runner_flow(TaskOutputPattern::DENY_MESSAGE));
    }
    if has_tracked_run_context(ctx) && has_denied_runner_binary(heads) {
        return Some(deny_runner_flow(
            "suite runs must stay on the tracked run; \
             do not switch into CI or GitHub workflows",
        ));
    }
    if has_python_inline(words) {
        return Some(deny_python());
    }
    if let Some(target) = make_target(words)
        && MakeTargetPrefix::is_denied_target(target)
    {
        return Some(HookMessage::ClusterBinary.into_result());
    }
    None
}

pub(crate) fn runner_tail_guards(words: &[String], heads: &[String]) -> HookResult {
    if has_denied_legacy_script(words) {
        return HookMessage::ClusterBinary.into_result();
    }
    if has_denied_cluster_binary(heads)
        || (!is_tracked_harness_command(words) && has_denied_cluster_binary_anywhere(words))
    {
        return HookMessage::ClusterBinary.into_result();
    }
    if has_admin_endpoint_hint(words)
        && !is_harness_head(heads)
        && !allows_wrapped_envoy_admin(words)
    {
        return HookMessage::AdminEndpoint.into_result();
    }
    HookResult::allow()
}
