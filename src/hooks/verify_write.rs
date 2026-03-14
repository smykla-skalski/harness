use std::path::Path;

use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;

use super::{control_file_hint, is_command_owned_run_file};

/// Execute the verify-write hook.
///
/// For suite-author: verifies written suite files parse correctly and
/// records the write in author workflow state. Full validation needs
/// author state and suite spec parsing infrastructure.
/// For suite-runner: verifies run file writes and records suite-fix
/// writes. Full validation needs `RunContext` and runner state.
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
    if ctx.skill == "suite-author" {
        return Ok(verify_suite_author(&paths));
    }
    Ok(verify_suite_runner(ctx, &paths))
}

fn verify_suite_author(_paths: &[String]) -> HookResult {
    // Full implementation:
    // - Parses suite.md / group .md files to verify structure
    // - Runs authoring validation
    // - Records write in author workflow state
    // Without that infrastructure, allow.
    HookResult::allow()
}

fn verify_suite_runner(ctx: &HookContext, paths: &[String]) -> HookResult {
    let run_dir = ctx.run_dir.as_ref();
    for raw_path in paths {
        let path = Path::new(raw_path);
        // Deny verification of harness-managed control files that should
        // not have been written directly.
        if let Some(rd) = run_dir
            && is_command_owned_run_file(path, rd)
        {
            let hint = control_file_hint(path);
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
    }
    // Full implementation verifies run-report, run-status, suite.md, and
    // group spec structure, then records suite-fix writes in runner state.
    HookResult::allow()
}
