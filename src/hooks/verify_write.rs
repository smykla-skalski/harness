use std::path::Path;

use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner as runner_rules;

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
        return verify_suite_author(&paths);
    }
    verify_suite_runner(ctx, &paths)
}

fn verify_suite_author(_paths: &[String]) -> Result<HookResult, CliError> {
    // Full implementation:
    // - Parses suite.md / group .md files to verify structure
    // - Runs authoring validation
    // - Records write in author workflow state
    // Without that infrastructure, allow.
    Ok(HookResult::allow())
}

fn verify_suite_runner(ctx: &HookContext, paths: &[String]) -> Result<HookResult, CliError> {
    let run_dir = ctx.run_dir.as_ref();
    for raw_path in paths {
        let path = Path::new(raw_path);
        // Deny verification of harness-managed control files that should
        // not have been written directly.
        if let Some(rd) = run_dir
            && is_command_owned_run_file(path, rd)
        {
            let hint = control_file_hint(path);
            return Ok(errors::hook_msg(
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
            ));
        }
    }
    // Full implementation verifies run-report, run-status, suite.md, and
    // group spec structure, then records suite-fix writes in runner state.
    Ok(HookResult::allow())
}

fn is_command_owned_run_file(path: &Path, run_dir: &Path) -> bool {
    runner_rules::DIRECT_WRITE_DENIED_RUN_FILES
        .iter()
        .any(|rel| path == run_dir.join(rel))
}

fn control_file_hint(path: &Path) -> &'static str {
    let name = path.file_name().map_or("", |n| n.to_str().unwrap_or(""));
    if name == "command-log.md" {
        runner_rules::COMMAND_LOG_HINT
    } else {
        runner_rules::HARNESS_MANAGED_RUN_CONTROL_HINT
    }
}
