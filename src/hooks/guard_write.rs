use std::path::Path;

use crate::errors::{self, CliError};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner as runner_rules;

/// Execute the guard-write hook.
///
/// Checks whether file writes are allowed for the active skill.
/// For suite-runner: denies writes to harness-managed control files and
/// paths outside the run surface. Full path validation needs `RunContext`;
/// this version checks what it can from path names alone.
/// For suite-author: denies writes outside the suite surface. Full
/// validation needs author workflow state; deferred parts allow.
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
        return guard_suite_author(&paths);
    }
    guard_suite_runner(ctx, &paths)
}

fn guard_suite_author(_paths: &[String]) -> Result<HookResult, CliError> {
    // Full implementation validates paths against the author workflow state
    // and suite directory. Without that infrastructure, allow.
    Ok(HookResult::allow())
}

fn guard_suite_runner(ctx: &HookContext, paths: &[String]) -> Result<HookResult, CliError> {
    let run_dir = ctx.run_dir.as_ref();
    for raw_path in paths {
        let path = Path::new(raw_path);
        // Deny direct writes to harness-managed control files.
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
    // Full run-surface and suite-fix validation needs RunContext and
    // runner workflow state. Allow remaining writes for now.
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
