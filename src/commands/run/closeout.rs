use crate::cli::RunDirArgs;
use crate::commands::resolve_run_context;
use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind, cow};
use crate::io::write_text;
use crate::schema::Verdict;
use crate::workflow::runner::{apply_event, ensure_execution_phase, read_runner_state};

/// Close out a run by verifying required artifacts.
///
/// When the overall verdict is still pending but groups have been recorded,
/// the verdict is computed automatically: any failure means fail, otherwise
/// pass (including runs that are all passed plus skipped).
///
/// # Errors
/// Returns `CliError` on failure.
pub fn closeout(run_dir_args: &RunDirArgs) -> Result<i32, CliError> {
    let ctx = resolve_run_context(run_dir_args)?;
    let run_dir = ctx.layout.run_dir();

    let required = [
        "commands/command-log.md",
        "manifests/manifest-index.md",
        "run-report.md",
        "run-status.json",
    ];

    for rel in &required {
        if !run_dir.join(rel).exists() {
            return Err(CliErrorKind::missing_closeout_artifact(*rel).into());
        }
    }

    let mut status = ctx
        .status
        .ok_or_else(|| -> CliError { CliErrorKind::MissingRunStatus.into() })?;

    if status.last_state_capture.is_none() {
        return Err(CliErrorKind::MissingStateCapture.into());
    }

    // Auto-compute verdict from counts when still pending.
    if status.overall_verdict == Verdict::Pending {
        let computed = compute_verdict_from_counts(
            status.counts.passed,
            status.counts.failed,
            status.counts.skipped,
        );
        if let Some(verdict) = computed {
            status.overall_verdict = verdict;
            status.completed_at = Some(utc_now());
            let status_json = serde_json::to_string_pretty(&status)
                .map_err(|e| CliErrorKind::serialize(cow!("closeout status update: {e}")))?;
            write_text(&ctx.layout.status_path(), &format!("{status_json}\n"))?;
            eprintln!(
                "auto-computed verdict from counts: {verdict} (passed={}, failed={}, skipped={})",
                status.counts.passed, status.counts.failed, status.counts.skipped
            );
        } else {
            return Err(CliErrorKind::VerdictPending.into());
        }
    }

    // Advance runner state to closeout then completed.
    let _ = ensure_execution_phase(&run_dir);
    if let Some(runner) = read_runner_state(&run_dir)? {
        let phase_str = runner.phase.to_string();
        if phase_str == "execution" {
            let _ = apply_event(&run_dir, "closeout-started", None, None);
            let _ = apply_event(&run_dir, "run-completed", None, None);
        } else if phase_str == "closeout" {
            let _ = apply_event(&run_dir, "run-completed", None, None);
        }
    }

    println!("run closeout is complete; start a new run id for any further bootstrap or execution");
    Ok(0)
}

/// Compute a verdict from run counts.
///
/// Returns `None` if no groups were reported.
fn compute_verdict_from_counts(passed: u32, failed: u32, skipped: u32) -> Option<Verdict> {
    let total = passed + failed + skipped;
    if total == 0 {
        return None;
    }
    if failed > 0 {
        Some(Verdict::Fail)
    } else {
        Some(Verdict::Pass)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compute_verdict_all_passed() {
        assert_eq!(compute_verdict_from_counts(5, 0, 0), Some(Verdict::Pass));
    }

    #[test]
    fn compute_verdict_passed_and_skipped() {
        assert_eq!(compute_verdict_from_counts(3, 0, 2), Some(Verdict::Pass));
    }

    #[test]
    fn compute_verdict_any_failed() {
        assert_eq!(compute_verdict_from_counts(3, 1, 0), Some(Verdict::Fail));
    }

    #[test]
    fn compute_verdict_all_skipped() {
        assert_eq!(compute_verdict_from_counts(0, 0, 5), Some(Verdict::Pass));
    }

    #[test]
    fn compute_verdict_no_groups() {
        assert_eq!(compute_verdict_from_counts(0, 0, 0), None);
    }
}
