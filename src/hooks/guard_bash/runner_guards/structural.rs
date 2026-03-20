use std::path::Path;

use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::guard_bash::predicates::deny_runner_flow;
use crate::hooks::protocol::hook_result::HookResult;
use crate::hooks::runner_policy::{
    ControlFileMutationBinary, ControlFileReadBinary, ScriptInterpreter, SuiteMutationBinary,
    TrackedHarnessSubcommand,
};
use crate::kernel::command_intent::{
    command_heads, is_shell_chain_op, is_shell_flow_word, is_shell_redirect_op,
    normalized_binary_name, path_like_words, semantic_harness_subcommand, semantic_harness_tail,
    significant_words,
};
use crate::kernel::run_surface::RunFile;

use super::{DELETE_FLAGS_WITH_VALUE, KUMA_DELETE_RESOURCE_KINDS};

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
        .any(|word| is_shell_chain_op(word) || is_shell_flow_word(word))
    {
        return deny_runner_flow(&format!(
            "do not wrap tracked `harness {}` commands in shell chains or loops; \
             run the tracked harness step directly",
            tracked[0]
        ));
    }
    HookResult::allow()
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
        .map(|head| normalized_binary_name(&head))
        .collect();
    if heads
        .iter()
        .any(|head| ScriptInterpreter::is_interpreter(head))
    {
        return deny_runner_flow(&format!(
            "do not use raw interpreters for run control files; {}",
            RunFile::CONTROL_HINT
        ));
    }
    for (index, word) in words.iter().enumerate() {
        if index + 1 >= words.len() {
            break;
        }
        if is_shell_redirect_op(word) {
            let target = &words[index + 1];
            if RunFile::ALL
                .iter()
                .filter(|file| file.is_harness_managed())
                .any(|file| target.contains(&file.to_string()))
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
        .any(|head| ControlFileMutationBinary::is_mutation_binary(head))
    {
        return deny_runner_flow(&format!(
            "do not mutate harness-managed run control files directly; {}",
            RunFile::CONTROL_HINT
        ));
    }
    if heads
        .iter()
        .any(|head| ControlFileReadBinary::is_read_binary(head))
    {
        return deny_runner_flow(&format!(
            "do not inspect harness-managed run control files directly; {}",
            RunFile::CONTROL_HINT
        ));
    }
    HookResult::allow()
}

pub(crate) fn deny_direct_command_log_access(ctx: &HookContext, words: &[String]) -> HookResult {
    let command_text = ctx.command_text().unwrap_or("");
    let references = ["commands/command-log.md", "command-log.md"];
    let mentioned = words
        .iter()
        .any(|word| references.iter().any(|reference| word.contains(reference)))
        || references
            .iter()
            .any(|reference| command_text.contains(reference));
    if !mentioned {
        return HookResult::allow();
    }
    deny_runner_flow(&format!(
        "do not inspect or mutate command-owned run logs directly; {}",
        RunFile::COMMAND_LOG_HINT
    ))
}

pub(crate) fn deny_raw_manifest_write(words: &[String], command_text: Option<&str>) -> HookResult {
    let command_text = command_text.unwrap_or("");
    let hints = ["/manifests/", "manifests/"];
    let any_mention = words
        .iter()
        .any(|word| hints.iter().any(|hint| word.contains(hint)))
        || hints.iter().any(|hint| command_text.contains(hint));
    if !any_mention {
        return HookResult::allow();
    }
    for (index, word) in words.iter().enumerate() {
        if index + 1 >= words.len() {
            break;
        }
        if is_shell_redirect_op(word) {
            let target = &words[index + 1];
            if hints.iter().any(|hint| target.contains(hint)) {
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
        .any(|head| SuiteMutationBinary::is_mutation_binary(&normalized_binary_name(head)))
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

pub(crate) fn deny_mixed_kuma_delete(words: &[String]) -> HookResult {
    let Some(delete_words) = tracked_kubectl_delete_words(words) else {
        return HookResult::allow();
    };
    if delete_words
        .iter()
        .any(|word| *word == "-f" || *word == "--filename" || word.starts_with("--filename="))
    {
        return HookResult::allow();
    }
    let mut positional = Vec::new();
    let mut skip_next = false;
    for word in &delete_words {
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
        .filter(|word| KUMA_DELETE_RESOURCE_KINDS.contains(word))
        .copied()
        .collect();
    let mut unique_kinds = kinds;
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

fn tracked_harness_subcommands(words: &[String]) -> Vec<String> {
    let significant = significant_words(words);
    let mut subcommands = Vec::new();
    for (index, word) in significant.iter().enumerate() {
        let name = Path::new(word)
            .file_name()
            .map_or("", |name| name.to_str().unwrap_or(""));
        if name != "harness" {
            continue;
        }
        if let Some(subcommand) = semantic_harness_subcommand(&significant[index..])
            && TrackedHarnessSubcommand::is_tracked(subcommand)
        {
            subcommands.push(subcommand.to_string());
        }
    }
    subcommands
}

fn run_control_files_mentioned(words: &[String], command_text: Option<&str>) -> Vec<String> {
    let command_text = command_text.unwrap_or("");
    RunFile::ALL
        .iter()
        .filter(|file| file.is_harness_managed())
        .map(ToString::to_string)
        .filter(|name| {
            words.iter().any(|word| word.contains(name.as_str()))
                || command_text.contains(name.as_str())
        })
        .collect()
}

fn tracked_kubectl_delete_words(words: &[String]) -> Option<Vec<String>> {
    let significant = significant_words(words);
    let semantic = semantic_harness_tail(&significant)?;
    if semantic_harness_subcommand(&significant) != Some("record") {
        return None;
    }
    for (index, word) in semantic.iter().enumerate() {
        let name = Path::new(word)
            .file_name()
            .map_or("", |name| name.to_str().unwrap_or(""));
        if name == "kubectl" && index + 1 < semantic.len() && semantic[index + 1] == "delete" {
            return Some(
                semantic[index + 2..]
                    .iter()
                    .map(|word| (*word).to_string())
                    .collect(),
            );
        }
    }
    None
}
