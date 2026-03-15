use std::fs;
use std::path::Path;

use crate::errors::{self, CliError};
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

fn verify_suite_author(paths: &[&str]) -> HookResult {
    for raw_path in paths {
        let path = Path::new(raw_path);
        let name = path.file_name().map_or("", |n| n.to_str().unwrap_or(""));
        if name == "amendments.md"
            && fs::read_to_string(path).is_ok_and(|content| content.trim().is_empty())
        {
            return errors::hook_msg(
                &errors::DENY_SUITE_INCOMPLETE,
                &[(
                    "details",
                    &format!("suite amendments entry is missing or empty: {raw_path}"),
                )],
            );
        }
    }
    HookResult::allow()
}

fn verify_suite_runner(ctx: &HookContext, paths: &[&str]) -> HookResult {
    let run_dir = ctx.effective_run_dir();
    // Suite-fix write tracking would use ctx.suite_dir() here once
    // record_suite_fix_write is available in the workflow module.
    for raw_path in paths {
        let path = normalize_path(Path::new(raw_path));
        if let Some(ref rd) = run_dir
            && is_command_owned_run_file(&path, rd)
        {
            let hint = control_file_hint(&path);
            return errors::hook_msg(
                &errors::DENY_RUNNER_FLOW_REQUIRED,
                &[
                    ("action", "edit run control files"),
                    (
                        "details",
                        &format!(
                            "{} is harness-managed; {hint}",
                            path.file_name()
                                .map_or("file", |n| n.to_str().unwrap_or("file"))
                        ),
                    ),
                ],
            );
        }
        let name = path.file_name().map_or("", |n| n.to_str().unwrap_or(""));
        if name == "amendments.md"
            && path.exists()
            && fs::read_to_string(&path).is_ok_and(|content| content.trim().is_empty())
        {
            return errors::hook_msg(
                &errors::DENY_SUITE_INCOMPLETE,
                &[(
                    "details",
                    &format!("suite amendments entry is missing or empty: {raw_path}"),
                )],
            );
        }
        // Track suite-fix writes when in triage with an active suite fix.
        // If the path is inside the suite dir and suite_fix is active,
        // the write is tracked; state update happens in the workflow module.
        // No additional checks needed for this path.
    }
    HookResult::allow()
}
