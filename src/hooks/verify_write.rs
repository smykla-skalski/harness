use std::fs;
use std::path::Path;

use crate::hooks::application::GuardContext as HookContext;
use crate::hooks::protocol::hook_result::HookResult;
use harness_kernel::errors::{CliError, HookMessage};

use super::effects::HookOutcome;

use super::normalize_path;

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
        |_ctx| Ok(verify_non_create_paths(&paths)),
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

/// Check a single path for an empty-amendments violation.
/// Returns `Some(outcome)` when the path triggers an early deny.
fn check_amendments_violation(raw_path: &Path, path: &Path) -> Option<HookOutcome> {
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

/// Verify writes for the branch that is not `suite:create`. Every confirmed
/// non-create skill lands here, `observe` included, so this is not specific to
/// the retired suite runner.
fn verify_non_create_paths(paths: &[&Path]) -> HookOutcome {
    for raw_path in paths {
        let path = normalize_path(raw_path);
        if let Some(violation) = check_amendments_violation(raw_path, &path) {
            return violation;
        }
    }
    HookOutcome::allow()
}

#[cfg(all(test, not(feature = "standalone-worker")))]
#[path = "verify_write/tests.rs"]
mod tests;
