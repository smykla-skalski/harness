use std::fs;
use std::path::Path;

use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;

use super::{control_file_hint, is_command_owned_run_file, normalize_path};

/// Execute the verify-write hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    if !ctx.skill_active {
        return Ok(HookResult::allow());
    }
    let paths = ctx.write_paths();
    if paths.is_empty() {
        return Ok(HookResult::allow());
    }
    if ctx.is_suite_author() {
        return Ok(verify_suite_author(&paths));
    }
    Ok(verify_suite_runner(ctx, &paths))
}

fn verify_suite_author(paths: &[&Path]) -> HookResult {
    for raw_path in paths {
        let name = raw_path
            .file_name()
            .map_or("", |n| n.to_str().unwrap_or(""));
        if name == "amendments.md"
            && fs::read_to_string(raw_path).is_ok_and(|content| content.trim().is_empty())
        {
            return HookMessage::SuiteIncomplete {
                details: format!(
                    "suite amendments entry is missing or empty: {}",
                    raw_path.display()
                )
                .into(),
            }
            .into_result();
        }
    }
    HookResult::allow()
}

fn verify_suite_runner(ctx: &HookContext, paths: &[&Path]) -> HookResult {
    let run_dir = ctx.effective_run_dir();
    // Suite-fix write tracking would use ctx.suite_dir() here once
    // record_suite_fix_write is available in the workflow module.
    for raw_path in paths {
        let path = normalize_path(raw_path);
        if let Some(ref rd) = run_dir
            && is_command_owned_run_file(&path, rd)
        {
            let hint = control_file_hint(&path);
            return HookMessage::RunnerFlowRequired {
                action: "edit run control files".into(),
                details: format!(
                    "{} is harness-managed; {hint}",
                    path.file_name()
                        .map_or("file", |n| n.to_str().unwrap_or("file"))
                )
                .into(),
            }
            .into_result();
        }
        let name = path.file_name().map_or("", |n| n.to_str().unwrap_or(""));
        if name == "amendments.md"
            && path.exists()
            && fs::read_to_string(&path).is_ok_and(|content| content.trim().is_empty())
        {
            return HookMessage::SuiteIncomplete {
                details: format!(
                    "suite amendments entry is missing or empty: {}",
                    raw_path.display()
                )
                .into(),
            }
            .into_result();
        }
        // Track suite-fix writes when in triage with an active suite fix.
        // If the path is inside the suite dir and suite_fix is active,
        // the write is tracked; state update happens in the workflow module.
        // No additional checks needed for this path.
    }
    HookResult::allow()
}
