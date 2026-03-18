use std::fs;
use std::path::Path;

use crate::errors::{CliError, HookMessage};
use crate::hooks::protocol::context::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use crate::run::workflow::RunnerWorkflowState;

use super::effects::{HookEffect, HookOutcome};

use super::{control_file_hint, is_command_owned_run_file, normalize_path};

/// Execute the verify-write hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookOutcome, CliError> {
    let paths = ctx.write_paths();
    if paths.is_empty() {
        return Ok(HookOutcome::allow());
    }
    super::dispatch_outcome_by_skill(
        ctx,
        |ctx| Ok(verify_suite_runner(ctx, &paths)),
        |_ctx| Ok(HookOutcome::from_hook_result(verify_suite_author(&paths))),
    )
}

fn verify_suite_author(paths: &[&Path]) -> HookResult {
    for raw_path in paths {
        let name = raw_path
            .file_name()
            .map_or("", |n| n.to_str().unwrap_or(""));
        if name == "amendments.md"
            && fs::read_to_string(raw_path).is_ok_and(|content| content.trim().is_empty())
        {
            return HookMessage::suite_incomplete(format!(
                "suite amendments entry is missing or empty: {}",
                raw_path.display()
            ))
            .into_result();
        }
    }
    HookResult::allow()
}

fn verify_suite_runner(ctx: &HookContext, paths: &[&Path]) -> HookOutcome {
    let run_dir = ctx.effective_run_dir();
    let suite_dir = ctx.suite_dir();
    let mut next_state = ctx.runner_state.clone();
    let mut tracked_state: Option<RunnerWorkflowState> = None;
    for raw_path in paths {
        let path = normalize_path(raw_path);
        if let Some(rd) = run_dir.as_deref()
            && is_command_owned_run_file(&path, rd)
        {
            let hint = control_file_hint(&path);
            return HookOutcome::from_hook_result(
                HookMessage::runner_flow_required(
                    "edit run control files",
                    format!(
                        "{} is harness-managed; {hint}",
                        path.file_name()
                            .map_or("file", |n| n.to_str().unwrap_or("file"))
                    ),
                )
                .into_result(),
            );
        }
        let name = path.file_name().map_or("", |n| n.to_str().unwrap_or(""));
        if name == "amendments.md"
            && path.exists()
            && fs::read_to_string(&path).is_ok_and(|content| content.trim().is_empty())
        {
            return HookOutcome::from_hook_result(
                HookMessage::suite_incomplete(format!(
                    "suite amendments entry is missing or empty: {}",
                    raw_path.display()
                ))
                .into_result(),
            );
        }
        if let Some(suite_root) = suite_dir.as_deref()
            && let Some(current_state) = next_state.as_ref()
        {
            let tracked_path = path.canonicalize().unwrap_or_else(|_| path.clone());
            if let Some(updated_state) =
                current_state.record_suite_fix_write(&tracked_path, suite_root)
            {
                next_state = Some(updated_state.clone());
                tracked_state = Some(updated_state);
            }
        }
    }
    let mut outcome = HookOutcome::allow();
    if let Some(state) = tracked_state {
        outcome = outcome.with_effect(HookEffect::WriteRunnerState {
            expected_transition_count: ctx
                .runner_state
                .as_ref()
                .map_or(0, |runner_state| runner_state.transition_count),
            state,
        });
    }
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hooks::protocol::context::GuardContext as HookContext;
    use crate::hooks::protocol::hook_result::Decision;
    use crate::hooks::protocol::payloads::HookEnvelopePayload;
    use crate::run::context::RunContext;
    use crate::run::workflow::{
        ManifestFixDecision, PreflightState, PreflightStatus, RunnerPhase, SuiteFixState,
    };
    use harness_testkit::RunDirBuilder;

    #[test]
    fn verify_suite_author_empty_amendments_denies() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let path = tmp.path().parent().unwrap().join("amendments.md");
        fs::write(&path, "   \n").unwrap();
        let result = verify_suite_author(&[path.as_path()]);
        assert_eq!(result.decision, Decision::Deny);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn verify_suite_author_nonempty_amendments_allows() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("amendments.md");
        fs::write(&path, "real content here\n").unwrap();
        let result = verify_suite_author(&[path.as_path()]);
        assert_eq!(result.decision, Decision::Allow);
    }

    #[test]
    fn verify_suite_runner_accumulates_suite_and_amendments_writes() {
        let tempdir = tempfile::tempdir().unwrap();
        let (run_dir, suite_dir) = RunDirBuilder::new(tempdir.path(), "r01").build();
        let suite_manifest = suite_dir.join("suite.md");
        let amendments = suite_dir.join("amendments.md");
        fs::write(&amendments, "changes\n").unwrap();

        let payload = HookEnvelopePayload {
            tool_name: "Write".to_string(),
            tool_input: serde_json::json!({
                "file_paths": [
                    suite_manifest.to_string_lossy(),
                    amendments.to_string_lossy(),
                ],
            }),
            tool_response: serde_json::Value::Null,
            last_assistant_message: None,
            transcript_path: None,
            stop_hook_active: false,
            raw_keys: vec![],
        };
        let mut context = HookContext::from_test_envelope("suite:run", payload);
        context.run_dir = Some(run_dir.clone());
        context.run = Some(RunContext::from_run_dir(&run_dir).unwrap());
        context.runner_state = Some(RunnerWorkflowState {
            phase: RunnerPhase::Triage,
            preflight: PreflightState {
                status: PreflightStatus::Complete,
            },
            failure: None,
            suite_fix: Some(SuiteFixState {
                approved_paths: vec![],
                suite_written: false,
                amendments_written: false,
                decision: ManifestFixDecision::SuiteAndRun,
            }),
            updated_at: String::new(),
            transition_count: 0,
            last_event: None,
            history: Vec::new(),
        });

        let outcome = execute(&context).unwrap();
        let next_state = outcome.state_transitions().next().unwrap();
        let suite_fix = next_state.suite_fix.as_ref().unwrap();
        assert!(suite_fix.suite_written);
        assert!(suite_fix.amendments_written);
    }
}
