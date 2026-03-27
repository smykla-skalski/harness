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

/// Check a single path for control-file or empty-amendments violations.
/// Returns `Some(outcome)` when the path triggers an early deny.
fn check_runner_path_violation(
    raw_path: &Path,
    path: &Path,
    run_dir: Option<&Path>,
) -> Option<HookOutcome> {
    if let Some(rd) = run_dir
        && is_command_owned_run_file(path, rd)
    {
        let hint = control_file_hint(path);
        return Some(HookOutcome::from_hook_result(
            HookMessage::runner_flow_required(
                "edit run control files",
                format!(
                    "{} is harness-managed; {hint}",
                    path.file_name()
                        .map_or("file", |n| n.to_str().unwrap_or("file"))
                ),
            )
            .into_result(),
        ));
    }
    let name = path.file_name().map_or("", |n| n.to_str().unwrap_or(""));
    if name == "amendments.md"
        && path.exists()
        && fs::read_to_string(path).is_ok_and(|content| content.trim().is_empty())
    {
        return Some(HookOutcome::from_hook_result(
            HookMessage::suite_incomplete(format!(
                "suite amendments entry is missing or empty: {}",
                raw_path.display()
            ))
            .into_result(),
        ));
    }
    None
}

/// Try to advance the suite-fix state machine for a single write path.
/// Returns the updated state when a transition occurred.
fn try_track_suite_fix(
    path: &Path,
    suite_root: &Path,
    current_state: &RunnerWorkflowState,
) -> Option<RunnerWorkflowState> {
    let tracked_path = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    current_state.record_suite_fix_write(&tracked_path, suite_root)
}

/// Check whether this path needs an amendment log entry.
/// Returns true for suite source files that are not `amendments.md` and not
/// inside the run directory.
fn needs_amendment(path: &Path, suite_dir_norm: Option<&Path>, run_dir_norm: Option<&Path>) -> bool {
    let name = path.file_name().map_or("", |n| n.to_str().unwrap_or(""));
    name != "amendments.md" && is_suite_source_write(path, suite_dir_norm, run_dir_norm)
}

fn verify_suite_runner(ctx: &HookContext, paths: &[&Path]) -> HookOutcome {
    let run_dir = ctx.effective_run_dir();
    let suite_dir = ctx.suite_dir();
    let suite_dir_norm = suite_dir.as_ref().map(|sd| normalize_path(sd));
    let run_dir_norm = run_dir.as_ref().map(|rd| normalize_path(rd));
    let mut next_state = ctx.runner_state.clone();
    let mut tracked_state: Option<RunnerWorkflowState> = None;
    let mut amendment_needed: Option<String> = None;
    for raw_path in paths {
        let path = normalize_path(raw_path);
        if let Some(violation) = check_runner_path_violation(raw_path, &path, run_dir.as_deref()) {
            return violation;
        }
        if amendment_needed.is_none()
            && needs_amendment(&path, suite_dir_norm.as_deref(), run_dir_norm.as_deref())
        {
            amendment_needed = Some(raw_path.display().to_string());
        }
        if let Some(suite_root) = suite_dir.as_deref()
            && let Some(current_state) = next_state.as_ref()
            && let Some(updated) = try_track_suite_fix(&path, suite_root, current_state)
        {
            next_state = Some(updated.clone());
            tracked_state = Some(updated);
        }
    }
    let mut outcome = if let Some(path) = amendment_needed {
        HookOutcome::from_hook_result(
            HookMessage::suite_amendment_required(path).into_result(),
        )
    } else {
        HookOutcome::allow()
    };
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

/// Returns true when `path` is inside the suite directory but not inside the run
/// directory. Run-dir writes are expected during a suite:run and do not need
/// amendment tracking.
fn is_suite_source_write(
    path: &Path,
    suite_dir_norm: Option<&Path>,
    run_dir_norm: Option<&Path>,
) -> bool {
    let Some(sdn) = suite_dir_norm else {
        return false;
    };
    if !path.starts_with(sdn) {
        return false;
    }
    if let Some(rdn) = run_dir_norm
        && path.starts_with(rdn)
    {
        return false;
    }
    true
}

#[cfg(test)]
#[path = "verify_write/tests.rs"]
mod tests;
