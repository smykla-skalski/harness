use std::path::Path;
use std::{fs, io};

use tracing::warn;

use crate::errors::{CliError, HookMessage};
use crate::hooks::protocol::context::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use crate::platform::cluster::ClusterMode;
use crate::run::context::RunContext;
use crate::run::workflow::{PreflightStatus, RunnerPhase, RunnerWorkflowState, SuiteFixState};

/// Parsed harness context: (subcommand, command label, words, run context).
type HarnessCommandContext<'a> = (&'a str, String, &'a [String], &'a RunContext);

fn subcommand_artifacts(subcommand: &str) -> Option<&'static [&'static str]> {
    match subcommand {
        "apply" => Some(&["manifests", "manifest-index.md"]),
        "capture" => Some(&["state"]),
        "preflight" => Some(&["artifacts", "preflight.json"]),
        "record" | "run" => Some(&["commands", "command-log.md"]),
        _ => None,
    }
}

/// Error code patterns that indicate a harness command failure requiring user
/// triage via the bug-found gate.
const FAILURE_ERROR_CODES: &[&str] = &["KSRCLI004", "KSRCLI014"];

/// Freeform patterns in command output that signal an apply or validation
/// failure even when a structured error code is absent.
const FAILURE_OUTPUT_PATTERNS: &[&str] = &["command failed", "apply failed", "validation failed"];

/// Execute the verify-bash hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    let Some((subcommand, command_label, words, run)) = extract_harness_context(ctx)? else {
        return Ok(HookResult::allow());
    };
    if let Some(result) = check_bug_found_gate(ctx, &command_label) {
        return Ok(result);
    }
    if let Some(result) = check_preflight_gate(ctx, subcommand) {
        return Ok(result);
    }
    Ok(verify_artifacts(
        ctx,
        subcommand,
        &command_label,
        words,
        run,
    ))
}

/// Extract the harness subcommand, words, and run context from the hook
/// context. Returns `None` when this hook should allow without further checks.
fn extract_harness_context(
    ctx: &HookContext,
) -> Result<Option<HarnessCommandContext<'_>>, CliError> {
    if !ctx.skill_active || !ctx.is_suite_runner() {
        return Ok(None);
    }
    let Some(command) = ctx.parsed_command()? else {
        return Ok(None);
    };
    let Some(invocation) = command.first_harness_invocation() else {
        return Ok(None);
    };
    let Some(subcommand) = invocation.subcommand() else {
        return Ok(None);
    };
    let Some(run) = &ctx.run else {
        return Ok(None);
    };
    Ok(Some((
        subcommand,
        invocation.command_label(),
        command.words(),
        run,
    )))
}

fn verify_artifacts(
    ctx: &HookContext,
    subcommand: &str,
    command_label: &str,
    words: &[String],
    run: &RunContext,
) -> HookResult {
    if subcommand == "cluster" {
        let result = check_cluster(words, run);
        if !result.is_denial() {
            maybe_resume_suite_fix(ctx, words);
        }
        return result;
    }
    if subcommand_artifacts(subcommand).is_none() || artifact_ready(subcommand, run) {
        maybe_resume_suite_fix(ctx, words);
        return HookResult::allow();
    }
    let target = missing_target(subcommand, run);
    HookMessage::missing_artifact(command_label.to_string(), target).into_result()
}

/// Check the command response for failure patterns during test execution.
///
/// Returns `Some(HookResult)` with a blocking deny when a harness command
/// failure is detected and the runner is in a phase that requires user
/// triage. Returns `None` when no gate is needed.
fn check_bug_found_gate(ctx: &HookContext, command_label: &str) -> Option<HookResult> {
    let state = ctx.runner_state.as_ref()?;

    // Only enforce during execution and closeout phases. Bootstrap and
    // preflight failures are handled by their own dedicated flows. Triage
    // means the runner is already handling a failure.
    if !matches!(
        state.phase(),
        RunnerPhase::Execution | RunnerPhase::Closeout
    ) {
        return None;
    }

    // If a failure is already being triaged, don't block again.
    if state.failure().is_some() {
        return None;
    }

    let response = ctx.response_text();
    if response.is_empty() {
        return None;
    }

    if !response_contains_failure(&response) {
        return None;
    }

    Some(HookMessage::bug_found_gate_required(command_label.to_string()).into_result())
}

/// Block `harness apply` when the runner has not completed preflight.
///
/// Returns `Some(HookResult)` with a deny when `harness apply` is called
/// while the runner phase is Bootstrap or Preflight with a non-complete
/// status. Returns `None` when no gate is needed.
fn check_preflight_gate(ctx: &HookContext, subcommand: &str) -> Option<HookResult> {
    if subcommand != "apply" {
        return None;
    }
    let state = ctx.runner_state.as_ref()?;
    let blocked = match state.phase() {
        RunnerPhase::Bootstrap => true,
        RunnerPhase::Preflight => state.preflight_status() != PreflightStatus::Complete,
        _ => false,
    };
    if !blocked {
        return None;
    }
    Some(
        HookMessage::runner_flow_required(
            "harness run apply",
            "Run `harness run preflight` before applying manifests. \
             Preflight materializes baselines and group YAML into prepared manifests.",
        )
        .into_result(),
    )
}

/// Returns `true` when the response text contains any known failure indicator.
fn response_contains_failure(response: &str) -> bool {
    for code in FAILURE_ERROR_CODES {
        if response.contains(code) {
            return true;
        }
    }
    let lower = response.to_lowercase();
    for pattern in FAILURE_OUTPUT_PATTERNS {
        if lower.contains(pattern) {
            return true;
        }
    }
    false
}

fn artifact_ready(subcommand: &str, run: &RunContext) -> bool {
    let run_dir = run.layout.run_dir();
    match subcommand {
        "preflight" => {
            run.preflight.is_some()
                && run.prepared_suite.is_some()
                && run.layout.prepared_suite_path().exists()
        }
        "capture" => {
            let state_dir = run.layout.state_dir();
            state_dir
                .read_dir()
                .is_ok_and(|mut entries| entries.next().is_some())
        }
        "apply" => {
            let index_path = run_dir.join("manifests").join("manifest-index.md");
            has_table_rows(&index_path)
        }
        _ => {
            let log_path = run_dir.join("commands").join("command-log.md");
            has_table_rows(&log_path)
        }
    }
}

fn has_table_rows(path: &Path) -> bool {
    match fs::read_to_string(path) {
        Ok(content) => content.matches("\n|").count() > 2,
        Err(e) if e.kind() == io::ErrorKind::NotFound => false,
        Err(e) => {
            warn!(path = %path.display(), %e, "cannot read file");
            false
        }
    }
}

fn missing_target(subcommand: &str, run: &RunContext) -> String {
    let run_dir = run.layout.run_dir();
    if subcommand == "preflight" && run_dir.join("artifacts").join("preflight.json").exists() {
        return run.layout.prepared_suite_path().display().to_string();
    }
    if let Some(parts) = subcommand_artifacts(subcommand) {
        let mut target = run_dir;
        for part in parts {
            target = target.join(part);
        }
        return target.display().to_string();
    }
    run_dir.display().to_string()
}

fn check_cluster(words: &[String], run: &RunContext) -> HookResult {
    let Some(mode) = cluster_mode(words) else {
        return HookResult::allow();
    };
    if !words
        .iter()
        .any(|w| w == "--run-dir" || w.starts_with("--run-dir="))
    {
        return HookResult::allow();
    }
    let target = run.layout.run_dir().join("current-deploy.json");
    if target.exists() {
        return HookResult::allow();
    }
    HookMessage::missing_artifact(
        format!("harness setup kuma cluster {mode}"),
        target.display().to_string(),
    )
    .into_result()
}

fn cluster_mode(words: &[String]) -> Option<&str> {
    words.get(2..)?.iter().find_map(|w| {
        let mode: ClusterMode = w.parse().ok()?;
        mode.is_up().then_some(w.as_str())
    })
}

fn maybe_resume_suite_fix(ctx: &HookContext, words: &[String]) {
    let Some(ref state) = ctx.runner_state else {
        return;
    };
    if words.len() < 2 {
        return;
    }
    let head = Path::new(&words[0])
        .file_name()
        .map_or("", |n| n.to_str().unwrap_or(""));
    if head != "harness" || words[1] == "runner-state" {
        return;
    }
    if ready_to_resume(state) {
        // The actual state transition is handled by the runner-state command.
        // This hook just validates artifacts; the resume write is deferred to
        // the CLI command layer.
    }
}

fn ready_to_resume(state: &RunnerWorkflowState) -> bool {
    if state.phase() != RunnerPhase::Triage {
        return false;
    }
    state
        .suite_fix()
        .is_some_and(SuiteFixState::ready_to_resume)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::absolute_paths)]

    use super::*;
    use crate::run::workflow::{
        FailureKind, FailureState, ManifestFixDecision, PreflightState, PreflightStatus,
        RunnerWorkflowState,
    };

    fn base_state(phase: RunnerPhase) -> RunnerWorkflowState {
        RunnerWorkflowState {
            phase,
            preflight: PreflightState {
                status: PreflightStatus::Pending,
            },
            failure: None,
            suite_fix: None,
            updated_at: String::new(),
            transition_count: 0,
            last_event: None,
            history: Vec::new(),
        }
    }

    // -- subcommand_artifacts --

    #[test]
    fn subcommand_artifacts_apply() {
        let arts = subcommand_artifacts("apply").unwrap();
        assert!(arts.contains(&"manifests"));
    }

    #[test]
    fn subcommand_artifacts_capture() {
        let arts = subcommand_artifacts("capture").unwrap();
        assert!(arts.contains(&"state"));
    }

    #[test]
    fn subcommand_artifacts_record() {
        let arts = subcommand_artifacts("record").unwrap();
        assert!(arts.contains(&"commands"));
    }

    #[test]
    fn subcommand_artifacts_unknown() {
        assert!(subcommand_artifacts("unknown").is_none());
    }

    // -- has_table_rows --

    #[test]
    fn has_table_rows_with_enough_rows() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(tmp.path(), "| h1 | h2 |\n|---|---|\n| a | b |\n| c | d |\n").unwrap();
        assert!(has_table_rows(tmp.path()));
    }

    #[test]
    fn has_table_rows_with_too_few() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        std::fs::write(tmp.path(), "| h1 | h2 |\n|---|---|\n").unwrap();
        assert!(!has_table_rows(tmp.path()));
    }

    #[test]
    fn has_table_rows_missing_file() {
        assert!(!has_table_rows(Path::new("/nonexistent/path/file.md")));
    }

    // -- ready_to_resume --

    #[test]
    fn ready_to_resume_triage_with_suite_fix_ready() {
        let mut state = base_state(RunnerPhase::Triage);
        state.suite_fix = Some(SuiteFixState {
            approved_paths: vec![],
            suite_written: true,
            amendments_written: true,
            decision: ManifestFixDecision::SuiteAndRun,
        });
        assert!(ready_to_resume(&state));
    }

    #[test]
    fn ready_to_resume_wrong_phase() {
        let state = base_state(RunnerPhase::Execution);
        assert!(!ready_to_resume(&state));
    }

    #[test]
    fn ready_to_resume_no_suite_fix() {
        let state = base_state(RunnerPhase::Triage);
        assert!(!ready_to_resume(&state));
    }

    #[test]
    fn ready_to_resume_suite_fix_incomplete() {
        let mut state = base_state(RunnerPhase::Triage);
        state.suite_fix = Some(SuiteFixState {
            approved_paths: vec![],
            suite_written: true,
            amendments_written: false,
            decision: ManifestFixDecision::SuiteAndRun,
        });
        assert!(!ready_to_resume(&state));
    }

    // -- response_contains_failure --

    #[test]
    fn response_contains_failure_detects_error_code() {
        assert!(response_contains_failure(
            "ERROR [KSRCLI004] command failed: harness apply"
        ));
    }

    #[test]
    fn response_contains_failure_detects_missing_file_code() {
        assert!(response_contains_failure(
            "ERROR [KSRCLI014] missing file: /tmp/manifest.yaml"
        ));
    }

    #[test]
    fn response_contains_failure_detects_command_failed_text() {
        assert!(response_contains_failure("Command failed with exit code 1"));
    }

    #[test]
    fn response_contains_failure_detects_apply_failed() {
        assert!(response_contains_failure(
            "apply failed for namespace default"
        ));
    }

    #[test]
    fn response_contains_failure_detects_validation_failed() {
        assert!(response_contains_failure(
            "validation failed: MeshHTTPRoute is invalid"
        ));
    }

    #[test]
    fn response_contains_failure_ignores_clean_output() {
        assert!(!response_contains_failure(
            "Successfully applied 3 manifests"
        ));
    }

    #[test]
    fn response_contains_failure_empty_string() {
        assert!(!response_contains_failure(""));
    }

    // -- check_bug_found_gate --

    #[test]
    fn check_bug_found_gate_blocks_during_execution() {
        let state = base_state(RunnerPhase::Execution);
        let ctx = stub_context_with_state_and_response(
            Some(state),
            Some("ERROR [KSRCLI004] command failed: harness apply"),
        );
        let result = check_bug_found_gate(&ctx, "apply");
        assert!(result.is_some());
        let hook_result = result.unwrap();
        assert_eq!(hook_result.code, "KSR016");
    }

    #[test]
    fn check_bug_found_gate_blocks_during_closeout() {
        let state = base_state(RunnerPhase::Closeout);
        let ctx = stub_context_with_state_and_response(
            Some(state),
            Some("ERROR [KSRCLI004] command failed: harness capture"),
        );
        let result = check_bug_found_gate(&ctx, "capture");
        assert!(result.is_some());
    }

    #[test]
    fn check_bug_found_gate_skips_during_bootstrap() {
        let state = base_state(RunnerPhase::Bootstrap);
        let ctx = stub_context_with_state_and_response(
            Some(state),
            Some("ERROR [KSRCLI004] command failed: harness setup kuma cluster"),
        );
        assert!(check_bug_found_gate(&ctx, "cluster").is_none());
    }

    #[test]
    fn check_bug_found_gate_skips_during_preflight() {
        let state = base_state(RunnerPhase::Preflight);
        let ctx = stub_context_with_state_and_response(
            Some(state),
            Some("ERROR [KSRCLI004] command failed: harness preflight"),
        );
        assert!(check_bug_found_gate(&ctx, "preflight").is_none());
    }

    #[test]
    fn check_bug_found_gate_skips_during_triage() {
        let state = base_state(RunnerPhase::Triage);
        let ctx = stub_context_with_state_and_response(
            Some(state),
            Some("ERROR [KSRCLI004] command failed: harness apply"),
        );
        assert!(check_bug_found_gate(&ctx, "apply").is_none());
    }

    #[test]
    fn check_bug_found_gate_skips_when_failure_already_set() {
        let mut state = base_state(RunnerPhase::Execution);
        state.failure = Some(FailureState {
            kind: FailureKind::Manifest,
            suite_target: None,
            message: None,
        });
        let ctx = stub_context_with_state_and_response(
            Some(state),
            Some("ERROR [KSRCLI004] command failed: harness apply"),
        );
        assert!(check_bug_found_gate(&ctx, "apply").is_none());
    }

    #[test]
    fn check_bug_found_gate_skips_when_no_state() {
        let ctx = stub_context_with_state_and_response(
            None,
            Some("ERROR [KSRCLI004] command failed: harness apply"),
        );
        assert!(check_bug_found_gate(&ctx, "apply").is_none());
    }

    #[test]
    fn check_bug_found_gate_skips_when_no_failure_in_response() {
        let state = base_state(RunnerPhase::Execution);
        let ctx = stub_context_with_state_and_response(
            Some(state),
            Some("Successfully applied 3 manifests"),
        );
        assert!(check_bug_found_gate(&ctx, "apply").is_none());
    }

    #[test]
    fn check_bug_found_gate_skips_when_response_empty() {
        let state = base_state(RunnerPhase::Execution);
        let ctx = stub_context_with_state_and_response(Some(state), None);
        assert!(check_bug_found_gate(&ctx, "apply").is_none());
    }

    // -- check_preflight_gate --

    #[test]
    fn preflight_gate_blocks_apply_during_bootstrap() {
        let state = base_state(RunnerPhase::Bootstrap);
        let ctx = stub_context_with_state_and_response(Some(state), None);
        let result = check_preflight_gate(&ctx, "apply");
        assert!(result.is_some());
        let hook_result = result.unwrap();
        assert_eq!(hook_result.code, "KSR014");
        assert!(hook_result.message.contains("preflight"));
    }

    #[test]
    fn preflight_gate_blocks_apply_during_preflight_pending() {
        let state = base_state(RunnerPhase::Preflight);
        let ctx = stub_context_with_state_and_response(Some(state), None);
        let result = check_preflight_gate(&ctx, "apply");
        assert!(result.is_some());
    }

    #[test]
    fn preflight_gate_blocks_apply_during_preflight_running() {
        let mut state = base_state(RunnerPhase::Preflight);
        state.preflight.status = PreflightStatus::Running;
        let ctx = stub_context_with_state_and_response(Some(state), None);
        let result = check_preflight_gate(&ctx, "apply");
        assert!(result.is_some());
    }

    #[test]
    fn preflight_gate_allows_apply_after_preflight_complete() {
        let mut state = base_state(RunnerPhase::Preflight);
        state.preflight.status = PreflightStatus::Complete;
        let ctx = stub_context_with_state_and_response(Some(state), None);
        assert!(check_preflight_gate(&ctx, "apply").is_none());
    }

    #[test]
    fn preflight_gate_allows_apply_during_execution() {
        let state = base_state(RunnerPhase::Execution);
        let ctx = stub_context_with_state_and_response(Some(state), None);
        assert!(check_preflight_gate(&ctx, "apply").is_none());
    }

    #[test]
    fn preflight_gate_allows_apply_during_triage() {
        let state = base_state(RunnerPhase::Triage);
        let ctx = stub_context_with_state_and_response(Some(state), None);
        assert!(check_preflight_gate(&ctx, "apply").is_none());
    }

    #[test]
    fn preflight_gate_skips_non_apply_subcommands() {
        let state = base_state(RunnerPhase::Bootstrap);
        let ctx = stub_context_with_state_and_response(Some(state), None);
        assert!(check_preflight_gate(&ctx, "cluster").is_none());
        assert!(check_preflight_gate(&ctx, "preflight").is_none());
        assert!(check_preflight_gate(&ctx, "capture").is_none());
    }

    #[test]
    fn preflight_gate_skips_when_no_state() {
        let ctx = stub_context_with_state_and_response(None, None);
        assert!(check_preflight_gate(&ctx, "apply").is_none());
    }

    /// Build a minimal `HookContext` with the given runner state and response.
    fn stub_context_with_state_and_response(
        runner_state: Option<RunnerWorkflowState>,
        response: Option<&str>,
    ) -> HookContext {
        use crate::hooks::protocol::payloads::HookEnvelopePayload;

        let payload = HookEnvelopePayload {
            tool_name: "Bash".to_string(),
            tool_response: response.map_or(serde_json::Value::Null, |text| {
                serde_json::json!({
                    "stdout": text,
                    "stderr": "",
                    "exit_code": 1,
                })
            }),
            ..HookEnvelopePayload::default()
        };

        let mut context = HookContext::from_test_envelope("suite:run", payload);
        context.runner_state = runner_state;
        context
    }
}
