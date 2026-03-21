use std::fs;
use std::path::Path;

use crate::errors::{CliError, HookMessage};
use crate::hooks::application::GuardContext as HookContext;
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
        |_ctx| Ok(HookOutcome::from_hook_result(verify_suite_create(&paths))),
    )
}

fn verify_suite_create(paths: &[&Path]) -> HookResult {
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
#[path = "verify_write/tests.rs"]
mod tests;
