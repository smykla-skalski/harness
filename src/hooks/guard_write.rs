use std::path::Path;

use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hook_payloads::HookContext;
use crate::rules::suite_runner::{RunDir, RunFile};
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
    // Validate paths are within the suite:new surface.
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
    let suite_dir_norm = suite_dir.as_ref().map(|sd| normalize_path(sd));

    for raw_path in paths {
        if let Some(result) = evaluate_runner_path(
            ctx,
            raw_path,
            run_dir.as_deref(),
            suite_dir.as_deref(),
            suite_dir_norm.as_deref(),
        ) {
            return result;
        }
    }

    HookResult::allow()
}

fn file_label(path: &Path) -> &str {
    path.file_name().and_then(|n| n.to_str()).unwrap_or("file")
}

fn deny_control_file(path: &Path) -> HookResult {
    let hint = control_file_hint(path);
    HookMessage::runner_flow_required(
        "edit run control files",
        format!("{} is harness-managed; {hint}", file_label(path)),
    )
    .into_result()
}

fn suite_fix_required(ctx: &HookContext) -> bool {
    ctx.runner_state
        .as_ref()
        .is_some_and(|state| state.suite_fix.is_none())
}

fn evaluate_runner_path(
    ctx: &HookContext,
    raw_path: &Path,
    run_dir: Option<&Path>,
    suite_dir: Option<&Path>,
    suite_dir_norm: Option<&Path>,
) -> Option<HookResult> {
    let path = normalize_path(raw_path);

    if let Some(rd) = run_dir {
        if is_command_owned_run_file(&path, rd) {
            return Some(deny_control_file(&path));
        }
        if allowed_suite_runner_path(&path, rd) {
            return None;
        }
    }

    if let Some(sdn) = suite_dir_norm
        && path.starts_with(sdn)
    {
        if suite_fix_required(ctx) {
            return Some(
                HookMessage::runner_flow_required(
                    "edit suite files",
                    "approved suite repair is required before editing suite files",
                )
                .into_result(),
            );
        }
        return None;
    }

    if run_dir.is_some() || suite_dir.is_some() {
        return Some(HookMessage::write_outside_run(raw_path.display().to_string()).into_result());
    }

    None
}

fn allowed_suite_runner_path(path: &Path, run_dir: &Path) -> bool {
    let norm = normalize_path(path);
    let rd_norm = normalize_path(run_dir);
    if RunFile::ALL
        .iter()
        .filter(|f| f.is_allowed())
        .any(|f| norm == normalize_path(&rd_norm.join(f.to_string())))
    {
        return true;
    }
    RunDir::ALL
        .iter()
        .any(|d| norm.starts_with(normalize_path(&rd_norm.join(d.to_string()))))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn allowed_path_for_run_metadata() {
        let run_dir = PathBuf::from("/tmp/runs/r1");
        let path = run_dir.join("run-metadata.json");
        assert!(allowed_suite_runner_path(&path, &run_dir));
    }

    #[test]
    fn allowed_path_for_run_dir_subdirectory() {
        let run_dir = PathBuf::from("/tmp/runs/r1");
        let path = run_dir.join("artifacts").join("some-file.txt");
        assert!(allowed_suite_runner_path(&path, &run_dir));
    }

    #[test]
    fn denied_path_outside_run_dir() {
        let run_dir = PathBuf::from("/tmp/runs/r1");
        let path = PathBuf::from("/tmp/other/file.txt");
        assert!(!allowed_suite_runner_path(&path, &run_dir));
    }

    #[test]
    fn file_label_with_filename() {
        assert_eq!(file_label(Path::new("/tmp/foo.txt")), "foo.txt");
    }

    #[test]
    fn file_label_without_filename() {
        assert_eq!(file_label(Path::new("/")), "file");
    }
}
