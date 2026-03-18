use std::fs;
use std::path::Path;

use crate::errors::{CliError, HookMessage};
use crate::hook::HookResult;
use crate::hooks::context::GuardContext as HookContext;

use super::effects;

use super::{control_file_hint, is_command_owned_run_file, normalize_path};

/// Execute the verify-write hook.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(ctx: &HookContext) -> Result<HookResult, CliError> {
    let paths = ctx.write_paths();
    if paths.is_empty() {
        return Ok(HookResult::allow());
    }
    super::dispatch_by_skill(
        ctx,
        |ctx| verify_suite_runner(ctx, &paths),
        |_ctx| Ok(verify_suite_author(&paths)),
    )
}

fn verify_suite_author(paths: &[&Path]) -> HookResult {
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

fn verify_suite_runner(ctx: &HookContext, paths: &[&Path]) -> Result<HookResult, CliError> {
    let run_dir = ctx.effective_run_dir();
    let suite_dir = ctx.suite_dir();
    for raw_path in paths {
        let path = normalize_path(raw_path);
        if let Some(rd) = run_dir.as_deref()
            && is_command_owned_run_file(&path, rd)
        {
            let hint = control_file_hint(&path);
            return Ok(HookMessage::runner_flow_required(
                "edit run control files",
                format!(
                    "{} is harness-managed; {hint}",
                    path.file_name()
                        .map_or("file", |n| n.to_str().unwrap_or("file"))
                ),
            )
            .into_result());
        }
        let name = path.file_name().map_or("", |n| n.to_str().unwrap_or(""));
        if name == "amendments.md"
            && path.exists()
            && fs::read_to_string(&path).is_ok_and(|content| content.trim().is_empty())
        {
            return Ok(HookMessage::suite_incomplete(format!(
                "suite amendments entry is missing or empty: {}",
                raw_path.display()
            ))
            .into_result());
        }
        if let Some(suite_root) = suite_dir.as_deref() {
            let _ = effects::transition_runner_state(ctx, |state| {
                state.record_suite_fix_write(&path, suite_root)
            })?;
        }
    }
    Ok(HookResult::allow())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hook::Decision;

    #[test]
    fn verify_suite_author_empty_amendments_denies() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        let path = tmp.path().parent().unwrap().join("amendments.md");
        fs::write(&path, "   \n").unwrap();
        let result = verify_suite_author(&[path.as_path()]);
        assert_eq!(result.decision, Decision::Deny);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn verify_suite_author_nonempty_amendments_allows() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("amendments.md");
        fs::write(&path, "real content here\n").unwrap();
        let result = verify_suite_author(&[path.as_path()]);
        assert_eq!(result.decision, Decision::Allow);
    }
}
