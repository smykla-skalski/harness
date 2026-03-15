use std::path::Path;

use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner as rules;
use crate::workflow::author::{self, can_write};

use super::{control_file_hint, is_command_owned_run_file, normalize_path};

/// Execute the guard-write hook.
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
        return Ok(guard_suite_author(ctx, &paths));
    }
    Ok(guard_suite_runner(ctx, &paths))
}

fn guard_suite_author(ctx: &HookContext, paths: &[&Path]) -> HookResult {
    let Some(state) = &ctx.author_state else {
        return HookResult::allow();
    };
    let suite_dir = state.suite_path();
    let sd_norm = suite_dir.as_ref().map(|sd| normalize_path(sd));
    let has_suite_output = sd_norm
        .as_ref()
        .is_some_and(|sdn| paths.iter().any(|p| normalize_path(p).starts_with(sdn)));
    if !has_suite_output {
        return HookResult::allow();
    }
    // Validate paths are within the suite-author surface.
    if let Some(ref sdn) = sd_norm {
        for raw_path in paths {
            let norm = normalize_path(raw_path);
            if !norm.starts_with(sdn) {
                continue;
            }
            if !author::suite_author_path_allowed(&norm, sdn) {
                return HookMessage::write_outside_suite(raw_path.display().to_string())
                    .into_result();
            }
        }
    }
    // Check if writing is allowed in the current phase.
    if let Err(reason) = can_write(state) {
        return HookMessage::approval_required("write suite files", reason).into_result();
    }
    HookResult::allow()
}

fn guard_suite_runner(ctx: &HookContext, paths: &[&Path]) -> HookResult {
    let run_dir = ctx.effective_run_dir();
    let suite_dir = ctx.suite_dir();
    let sd_norm = suite_dir.as_ref().map(|sd| normalize_path(sd));
    for raw_path in paths {
        let path = normalize_path(raw_path);
        // Deny direct writes to harness-managed control files.
        if let Some(ref rd) = run_dir {
            if is_command_owned_run_file(&path, rd) {
                let hint = control_file_hint(&path);
                return HookMessage::runner_flow_required(
                    "edit run control files",
                    format!(
                        "{} is harness-managed; {hint}",
                        path.file_name()
                            .map_or("file", |n| n.to_str().unwrap_or("file"))
                    ),
                )
                .into_result();
            }
            if allowed_suite_runner_path(&path, rd) {
                continue;
            }
        }
        // Check if path is within suite dir (suite-fix writes).
        if let Some(ref sdn) = sd_norm
            && path.starts_with(sdn)
        {
            if let Some(ref state) = ctx.runner_state
                && state.suite_fix.is_none()
            {
                return HookMessage::runner_flow_required(
                    "edit suite files",
                    "approved suite repair is required before editing suite files",
                )
                .into_result();
            }
            continue;
        }
        // Path outside run surface.
        if run_dir.is_some() || suite_dir.is_some() {
            return HookMessage::write_outside_run(raw_path.display().to_string()).into_result();
        }
    }
    HookResult::allow()
}

fn allowed_suite_runner_path(path: &Path, run_dir: &Path) -> bool {
    let norm = normalize_path(path);
    let rd_norm = normalize_path(run_dir);
    if rules::ALLOWED_RUN_FILES
        .iter()
        .any(|rel| norm == normalize_path(&rd_norm.join(rel)))
    {
        return true;
    }
    rules::ALLOWED_RUN_DIRS
        .iter()
        .any(|rel| norm.starts_with(normalize_path(&rd_norm.join(rel))))
}
