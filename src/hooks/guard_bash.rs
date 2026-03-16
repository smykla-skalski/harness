use std::path::Path;

use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner::{
    AdminEndpointHint, ClusterBinary, ControlFileMutationBinary, ControlFileReadBinary,
    LegacyScript, MakeTargetPrefix, PythonBinary, RunFile, RunnerBinary, ScriptInterpreter,
    SuiteMutationBinary, TaskOutputPattern, TrackedHarnessSubcommand,
};
use crate::shell_parse::{
    command_heads, is_env_assignment, is_shell_chain_op, is_shell_control_op, is_shell_flow_word,
    is_shell_redirect_op, normalized_binary_name, path_like_words, significant_words,
};
use crate::workflow::runner::{RunnerPhase, RunnerWorkflowState};

fn is_run_scope_flag(s: &str) -> bool {
    matches!(s, "--run-dir" | "--run-id" | "--run-root")
        || s.starts_with("--run-dir=")
        || s.starts_with("--run-id=")
        || s.starts_with("--run-root=")
}

/// Execute the guard-bash hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    let words = match ctx.command_words() {
        Ok(w) => w,
        Err(e) => {
            return Ok(HookMessage::runner_flow_required(
                "parse command",
                format!("shell tokenization failed: {e}"),
            )
            .into_result());
        }
    };
    if words.is_empty() {
        return Ok(HookResult::allow());
    }
    let heads = command_heads(&words);
    if ctx.is_suite_author() {
        return Ok(guard_suite_author(ctx, &words, &heads));
    }
    Ok(guard_suite_runner(ctx, &words, &heads))
}

fn guard_suite_author(_ctx: &HookContext, words: &[String], heads: &[String]) -> HookResult {
    if has_denied_cluster_binary(heads) || has_denied_cluster_binary_anywhere(words) {
        return HookMessage::ClusterBinary.into_result();
    }
    if has_python_inline(words) {
        return deny_python();
    }
    if !is_harness_head(heads) && has_admin_endpoint_hint(words) {
        return HookMessage::AdminEndpoint.into_result();
    }
    let suite_mutation = deny_author_suite_storage_mutation(words);
    if !suite_mutation.code.is_empty() {
        return suite_mutation;
    }
    HookResult::allow()
}

fn deny_author_suite_storage_mutation(words: &[String]) -> HookResult {
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
                 use `harness authoring-begin` which handles conflicts",
            )
            .into_result();
        }
    }
    HookResult::allow()
}

fn guard_suite_runner(ctx: &HookContext, words: &[String], heads: &[String]) -> HookResult {
    let phase_result = guard_runner_phase(ctx, words);
    if !phase_result.code.is_empty() {
        return phase_result;
    }

    if has_task_output_access(words, ctx.command_text()) {
        return deny_runner_flow(TaskOutputPattern::DENY_MESSAGE);
    }

    if has_denied_runner_binary(heads) {
        return deny_runner_flow(
            "suite runs must stay on the tracked run; \
             do not switch into CI or GitHub workflows",
        );
    }
    if has_python_inline(words) {
        return deny_python();
    }
    if let Some(target) = make_target(words)
        && MakeTargetPrefix::is_denied_target(target)
    {
        return HookMessage::ClusterBinary.into_result();
    }

    let batched = deny_batched_tracked_harness_commands(words);
    if !batched.code.is_empty() {
        return batched;
    }

    let log_access = deny_direct_command_log_access(ctx, words);
    if !log_access.code.is_empty() {
        return log_access;
    }

    let control_mut = deny_harness_managed_run_control_mutation(ctx, words);
    if !control_mut.code.is_empty() {
        return control_mut;
    }

    let raw_manifest = deny_raw_manifest_write(words, ctx.command_text());
    if !raw_manifest.code.is_empty() {
        return raw_manifest;
    }

    let suite_mutation = deny_suite_storage_mutation(words);
    if !suite_mutation.code.is_empty() {
        return suite_mutation;
    }

    let mixed_delete = deny_mixed_kuma_delete(words);
    if !mixed_delete.code.is_empty() {
        return mixed_delete;
    }

    if has_denied_legacy_script(words) {
        return HookMessage::ClusterBinary.into_result();
    }

    if has_denied_cluster_binary(heads)
        || (!is_tracked_harness_command(words) && has_denied_cluster_binary_anywhere(words))
    {
        return HookMessage::ClusterBinary.into_result();
    }

    if has_admin_endpoint_hint(words) {
        if is_harness_head(heads) || allows_wrapped_envoy_admin(words) {
            return HookResult::allow();
        }
        return HookMessage::AdminEndpoint.into_result();
    }
    HookResult::allow()
}

fn guard_runner_phase(ctx: &HookContext, words: &[String]) -> HookResult {
    if let Some(ref run) = ctx.run
        && let Some(reason) = completed_run_reuse_reason(words)
        && let Some(ref status) = run.status
        && status.overall_verdict.is_finalized()
    {
        return deny_runner_flow(&format!(
            "{reason}. Start a new run with \
             `harness init --run-id <new-run-id> ...` first"
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
    if sig.len() < 2 {
        return None;
    }
    let head = Path::new(&sig[0])
        .file_name()
        .map_or("", |n| n.to_str().unwrap_or(""));
    if head != "harness" {
        return None;
    }
    let sub = sig[1].as_str();
    match sub {
        "cluster" => {
            let mode = if sig.len() >= 3 { sig[2].as_str() } else { "" };
            if mode.ends_with("-down") {
                None
            } else {
                Some(
                    "the active run is already final; do not start or \
                     redeploy clusters on it",
                )
            }
        }
        "report" => {
            if sig.len() >= 3 && sig[2] == "check" {
                None
            } else {
                Some("the active run is already final; do not mutate the finalized report")
            }
        }
        "runner-state" => {
            let has_event = sig
                .iter()
                .any(|w| w == "--event" || w.starts_with("--event="));
            if has_event {
                Some("the active run is already final; do not reopen or advance it")
            } else {
                None
            }
        }
        "apply" | "bootstrap" | "capture" | "diff" | "envoy" | "gateway" | "kumactl"
        | "preflight" | "record" | "run" | "validate" => Some(
            "the active run is already final; start a new run before \
             continuing bootstrap or execution",
        ),
        _ => None,
    }
}

fn has_explicit_run_scope(words: &[String]) -> bool {
    let sig = significant_words(words);
    sig.iter().any(|w| is_run_scope_flag(w))
}

fn allowed_command(state: &RunnerWorkflowState, words: &[String]) -> (bool, Option<&'static str>) {
    let sig = significant_words(words);
    if sig.len() < 2 {
        return (true, None);
    }
    let head = Path::new(&sig[0])
        .file_name()
        .map_or("", |n| n.to_str().unwrap_or(""));
    if head != "harness" {
        return (true, None);
    }
    let sub = sig[1].as_str();
    match state.phase {
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
            if state.suite_fix.is_some() {
                return (true, None);
            }
            (true, None)
        }
        _ => (true, None),
    }
}

fn deny_batched_tracked_harness_commands(words: &[String]) -> HookResult {
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
        if i + 1 >= sig.len() {
            break;
        }
        let name = Path::new(word)
            .file_name()
            .map_or("", |n| n.to_str().unwrap_or(""));
        if name != "harness" {
            continue;
        }
        let sub = &sig[i + 1];
        if !sub.starts_with('-') && TrackedHarnessSubcommand::is_tracked(sub) {
            subs.push(sub.clone());
        }
    }
    subs
}

fn deny_harness_managed_run_control_mutation(ctx: &HookContext, words: &[String]) -> HookResult {
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

fn deny_direct_command_log_access(ctx: &HookContext, words: &[String]) -> HookResult {
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

fn deny_raw_manifest_write(words: &[String], command_text: Option<&str>) -> HookResult {
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

fn deny_suite_storage_mutation(words: &[String]) -> HookResult {
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

fn deny_mixed_kuma_delete(words: &[String]) -> HookResult {
    let Some(dw) = tracked_kubectl_delete_words(words) else {
        return HookResult::allow();
    };
    if dw
        .iter()
        .any(|w| w == "-f" || w == "--filename" || w.starts_with("--filename="))
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
    if sig.len() < 4 {
        return None;
    }
    let head = Path::new(&sig[0])
        .file_name()
        .map_or("", |n| n.to_str().unwrap_or(""));
    if head != "harness" || !matches!(sig[1].as_str(), "run" | "record") {
        return None;
    }
    for (i, word) in sig.iter().enumerate() {
        let name = Path::new(word)
            .file_name()
            .map_or("", |n| n.to_str().unwrap_or(""));
        if name == "kubectl" && i + 1 < sig.len() && sig[i + 1] == "delete" {
            return Some(sig[i + 2..].to_vec());
        }
    }
    None
}

fn deny_runner_flow(details: &str) -> HookResult {
    HookMessage::runner_flow_required("run this command", details.to_string()).into_result()
}

fn is_harness_head(heads: &[String]) -> bool {
    !heads.is_empty() && heads.iter().all(|h| h == "harness")
}

fn is_tracked_harness_command(words: &[String]) -> bool {
    let sig = significant_words(words);
    sig.len() >= 2
        && normalized_binary_name(&sig[0]) == "harness"
        && TrackedHarnessSubcommand::is_tracked(&sig[1])
}

fn has_denied_cluster_binary(heads: &[String]) -> bool {
    heads.iter().any(|h| ClusterBinary::is_denied(h))
}

fn has_denied_cluster_binary_anywhere(words: &[String]) -> bool {
    words
        .iter()
        .any(|w| ClusterBinary::is_denied(&normalized_binary_name(w)))
}

fn has_denied_runner_binary(heads: &[String]) -> bool {
    heads.iter().any(|h| RunnerBinary::is_denied(h))
}

fn has_task_output_access(words: &[String], command_text: Option<&str>) -> bool {
    let command = command_text.unwrap_or("");
    if TaskOutputPattern::matches_any(command) {
        return true;
    }
    words.iter().any(|w| TaskOutputPattern::matches_any(w))
}

fn has_admin_endpoint_hint(words: &[String]) -> bool {
    words.iter().any(|w| AdminEndpointHint::contains_hint(w))
}

fn has_python_inline(words: &[String]) -> bool {
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

fn deny_python() -> HookResult {
    HookMessage::approval_required(
        "use python",
        "do not use python for JSON parsing; \
         use jq for JSON filtering or harness envoy capture for Envoy admin data",
    )
    .into_result()
}

fn has_denied_legacy_script(words: &[String]) -> bool {
    words.iter().any(|w| {
        let name = Path::new(w)
            .file_name()
            .map_or("", |n| n.to_str().unwrap_or(""));
        LegacyScript::is_denied(name)
    })
}

fn make_target(words: &[String]) -> Option<&str> {
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

fn allows_wrapped_envoy_admin(words: &[String]) -> bool {
    let sig: Vec<&str> = words
        .iter()
        .filter(|w| !is_shell_control_op(w) && !is_env_assignment(w))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hook::Decision;
    use crate::hook_payloads::{HookContext, HookEnvelopePayload};

    fn ctx(skill: &str, command: &str) -> HookContext {
        HookContext::from_envelope(
            skill,
            HookEnvelopePayload {
                tool_name: "Bash".to_string(),
                tool_input: serde_json::json!({
                    "command": command,
                }),
                tool_response: serde_json::Value::Null,
                last_assistant_message: None,
                transcript_path: None,
                stop_hook_active: false,
                raw_keys: vec![],
            },
        )
    }

    #[test]
    fn denies_direct_kubectl() {
        let c = ctx("suite:run", "kubectl get pods");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
    }

    #[test]
    fn denies_legacy_script_via_python() {
        let c = ctx("suite:run", "python3 tools/record_command.py -- echo hello");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
    }

    #[test]
    fn denies_kumactl_path_after_shell_op() {
        let c = ctx(
            "suite:run",
            "ls -la /tmp/kumactl && /tmp/kumactl version 2>&1",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
    }

    // Catches kumactl anywhere in command words, including path-like arguments.
    #[test]
    fn denies_kumactl_in_path_arg() {
        let c = ctx("suite:run", "ls -la /tmp/kumactl");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
    }

    #[test]
    fn allows_kumactl_in_harness_run() {
        let c = ctx(
            "suite:run",
            "harness run --phase setup --label kumactl-version kumactl version",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn allows_harness_envoy_capture() {
        let c = ctx(
            "suite:run",
            "harness envoy capture --phase verify --label config-dump --namespace kuma-demo \
             --workload deploy/demo-client --admin-path /config_dump",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn denies_github_sidequest() {
        let c = ctx("suite:run", "gh run view 12345");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
    }

    #[test]
    fn denies_direct_kubectl_for_suite_author() {
        let c = ctx("suite:new", "kubectl get pods");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
    }

    #[test]
    fn denies_rm_rf_suite_dir_for_suite_author() {
        let c = ctx(
            "suite:new",
            "rm -rf ~/.local/share/kuma/suites/motb-compliance",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(r.message.contains("mutate suite storage"));
    }

    #[test]
    fn allows_harness_wrapper_for_suite_author() {
        let c = ctx("suite:new", "harness authoring-show --kind session");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn allows_empty_command() {
        let c = ctx("suite:run", "");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn denies_helm_direct() {
        let c = ctx("suite:run", "helm install kuma kuma/kuma");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
    }

    #[test]
    fn denies_docker_direct() {
        let c = ctx("suite:run", "docker ps");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
    }

    #[test]
    fn denies_k3d_direct() {
        let c = ctx("suite:run", "k3d cluster list");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
    }

    #[test]
    fn allows_harness_record() {
        let c = ctx(
            "suite:run",
            "harness record --phase verify --label test -- echo hello",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn allows_inactive_skill() {
        let mut c = ctx("suite:run", "kubectl get pods");
        c.skill_active = false;
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn denies_admin_endpoint_direct() {
        let c = ctx("suite:run", "wget -qO- localhost:9901/config_dump");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
    }

    #[test]
    fn denies_mixed_kuma_resource_delete() {
        let c = ctx(
            "suite:run",
            "harness record --phase cleanup --label cleanup-g04 -- \
             kubectl delete meshopentelemetrybackend otel-runtime \
             meshmetric metrics-runtime -n kuma-system",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(
            r.message
                .contains("cleanup must not mix multiple resource kinds")
        );
    }

    #[test]
    fn allows_single_kuma_resource_delete_via_harness_record() {
        let c = ctx(
            "suite:run",
            "harness record --phase cleanup --label cleanup-g05 -- \
             kubectl delete meshopentelemetrybackend otel-e2e -n kuma-system",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn denies_tracked_harness_in_loop() {
        let c = ctx(
            "suite:run",
            "for i in 01 02 03; do \
             harness apply --manifest \"g10/${i}.yaml\" --step \"g10-manifest-${i}\" || break; \
             done",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(r.message.contains("shell chains or loops"));
    }

    #[test]
    fn denies_chained_tracked_harness() {
        let c = ctx(
            "suite:run",
            "sleep 5 && harness run --phase verify --label ctx kubectl config current-context",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(r.message.contains("run the tracked harness step directly"));
    }

    #[test]
    fn allows_kubectl_in_harness_record_pipe() {
        let c = ctx(
            "suite:run",
            "harness record --phase verify --label pods \
             kubectl get pods -o json | jq '.items[].metadata.name'",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn make_target_extracts() {
        let words: Vec<String> = vec!["make", "k3d/stop"]
            .into_iter()
            .map(String::from)
            .collect();
        assert_eq!(make_target(&words), Some("k3d/stop"));
    }

    #[test]
    fn make_target_none_without_make() {
        let words: Vec<String> = vec!["echo", "hello"]
            .into_iter()
            .map(String::from)
            .collect();
        assert_eq!(make_target(&words), None);
    }

    #[test]
    fn is_tracked_harness_command_positive() {
        let words: Vec<String> = vec![
            "harness", "record", "--phase", "verify", "--", "kubectl", "get", "pods",
        ]
        .into_iter()
        .map(String::from)
        .collect();
        assert!(is_tracked_harness_command(&words));

        let words: Vec<String> = vec!["harness", "run", "--phase", "setup", "kumactl", "version"]
            .into_iter()
            .map(String::from)
            .collect();
        assert!(is_tracked_harness_command(&words));
    }

    #[test]
    fn is_tracked_harness_command_negative() {
        let words: Vec<String> = vec!["kubectl", "get", "pods"]
            .into_iter()
            .map(String::from)
            .collect();
        assert!(!is_tracked_harness_command(&words));

        let words: Vec<String> = vec!["harness", "authoring-show", "--kind", "session"]
            .into_iter()
            .map(String::from)
            .collect();
        assert!(!is_tracked_harness_command(&words));

        let words: Vec<String> = vec!["ls", "-la"].into_iter().map(String::from).collect();
        assert!(!is_tracked_harness_command(&words));
    }

    #[test]
    fn is_tracked_harness_subcommand_includes_token() {
        assert!(TrackedHarnessSubcommand::is_tracked("token"));
    }

    #[test]
    fn is_tracked_harness_subcommand_includes_service() {
        assert!(TrackedHarnessSubcommand::is_tracked("service"));
    }

    #[test]
    fn allows_harness_token_command() {
        let c = ctx(
            "suite:run",
            "harness token dataplane --name demo --mesh default",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn allows_harness_service_command() {
        let c = ctx(
            "suite:run",
            "harness service up demo --image kuma-dp:latest --port 5050",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn denies_python_inline_in_suite_new() {
        let c = ctx(
            "suite:new",
            "harness authoring-show --kind coverage | python3 -c \"import json, sys; print(json.load(sys.stdin))\"",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(r.message.contains("do not use python"));
    }

    #[test]
    fn denies_python_inline_in_suite_run() {
        let c = ctx(
            "suite:run",
            "kubectl get pods -o json | python3 -c \"import json, sys; print(json.load(sys.stdin))\"",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(r.message.contains("do not use python"));
    }

    #[test]
    fn denies_python_stdin_pipe() {
        let c = ctx("suite:run", "cat data.json | python3 -");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(r.message.contains("do not use python"));
    }

    #[test]
    fn denies_python_without_version_suffix() {
        let c = ctx("suite:new", "echo '{}' | python -c \"import json\"");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(r.message.contains("do not use python"));
    }

    #[test]
    fn allows_python_version_check() {
        let c = ctx("suite:run", "python3 --version");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn allows_python_script_file() {
        let c = ctx("suite:new", "python3 script.py");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }

    #[test]
    fn denies_cat_task_output_file() {
        let c = ctx(
            "suite:run",
            "cat /private/tmp/claude-501/sessions/abc123/tasks/xyz.output",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(r.message.contains("TaskOutput tool"));
    }

    #[test]
    fn denies_sleep_then_cat_task_output() {
        let c = ctx(
            "suite:run",
            "sleep 120 && cat /private/tmp/claude-501/sessions/abc123/tasks/xyz.output",
        );
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(r.message.contains("TaskOutput tool"));
    }

    #[test]
    fn denies_task_output_glob() {
        let c = ctx("suite:run", "cat tasks/*.output");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(r.message.contains("TaskOutput tool"));
    }

    #[test]
    fn denies_task_b8m_prefix() {
        let c = ctx("suite:run", "cat tasks/b8m-something.output");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Deny);
        assert!(r.message.contains("TaskOutput tool"));
    }

    #[test]
    fn allows_unrelated_cat_command() {
        let c = ctx("suite:run", "cat /tmp/some-other-file.txt");
        let r = execute(&c).unwrap();
        assert_eq!(r.decision, Decision::Allow);
    }
}
