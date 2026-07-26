use std::fs;
use std::path::Path;

use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use harness_kernel::errors::{CliError, HookMessage};

use super::effects::HookOutcome;

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

fn verify_suite_runner(ctx: &HookContext, paths: &[&Path]) -> HookOutcome {
    let run_dir = ctx.effective_run_dir();
    for raw_path in paths {
        let path = normalize_path(raw_path);
        if let Some(violation) = check_runner_path_violation(raw_path, &path, run_dir.as_deref()) {
            return violation;
        }
    }
    HookOutcome::allow()
}

#[cfg(all(test, not(feature = "standalone-worker")))]
#[path = "verify_write/tests.rs"]
mod tests;
