use std::fmt::Write as _;
use std::path::PathBuf;

use clap::{Args, Subcommand};

use crate::audit_log::write_run_status_with_audit;
use crate::commands::{RunDirArgs, resolve_run_dir};
use crate::context::RunContext;
use crate::core_defs::utc_now;
use crate::errors::{CliError, CliErrorKind};
use crate::rules::suite_runner::{REPORT_CODE_BLOCK_LIMIT, REPORT_LINE_LIMIT};
use crate::schema::{ExecutedGroupChange, GroupVerdict, RunReport, RunStatus};
use crate::workflow::runner::ensure_execution_phase;

#[non_exhaustive]
/// Report validation and group finalization.
#[derive(Debug, Clone, Subcommand)]
pub enum ReportCommand {
    /// Validate report compactness.
    Check {
        /// Report path; defaults to the tracked run report.
        #[arg(long)]
        report: Option<String>,
    },
    /// Finalize a completed group.
    Group {
        /// Completed group ID (e.g. g02).
        #[arg(long)]
        group_id: String,
        /// Recorded group verdict.
        #[arg(long, value_parser = ["pass", "fail", "skip"])]
        status: String,
        /// Evidence file path; repeat to record multiple artifacts.
        #[arg(long)]
        evidence: Vec<String>,
        /// Recorded evidence label to resolve to the latest matching artifact.
        #[arg(long)]
        evidence_label: Vec<String>,
        /// Optional state-capture label to snapshot pod state before finalizing.
        #[arg(long)]
        capture_label: Option<String>,
        /// Optional one-line note to include in the story result.
        #[arg(long)]
        note: Option<String>,
        /// Run-directory resolution.
        #[command(flatten)]
        run_dir: RunDirArgs,
    },
}

/// Arguments for `harness report`.
#[derive(Debug, Clone, Args)]
pub struct ReportArgs {
    /// Report subcommand.
    #[command(subcommand)]
    pub cmd: ReportCommand,
}

/// Report validation and group finalization.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn report(cmd: &ReportCommand) -> Result<i32, CliError> {
    match cmd {
        ReportCommand::Check { report } => report_check(report.as_deref()),
        ReportCommand::Group {
            group_id,
            status,
            evidence,
            evidence_label,
            capture_label,
            note,
            run_dir,
        } => report_group(
            group_id,
            status,
            evidence,
            evidence_label,
            capture_label.as_deref(),
            note.as_deref(),
            run_dir,
        ),
    }
}

fn report_check(report_path: Option<&str>) -> Result<i32, CliError> {
    let path = if let Some(p) = report_path {
        PathBuf::from(p)
    } else {
        let context = RunContext::from_current()?.ok_or_else(|| -> CliError {
            CliErrorKind::missing_run_context_value("report").into()
        })?;
        context.layout.report_path()
    };

    if !path.exists() {
        println!("no report generated yet");
        return Ok(0);
    }

    let rpt = RunReport::from_markdown(&path)?;
    let body = rpt.to_markdown();
    let line_count = body.lines().count();
    let code_blocks = body.matches("```").count() / 2;

    if line_count > REPORT_LINE_LIMIT {
        return Err(CliErrorKind::report_line_limit(
            line_count.to_string(),
            REPORT_LINE_LIMIT.to_string(),
        )
        .into());
    }
    if code_blocks > REPORT_CODE_BLOCK_LIMIT {
        return Err(CliErrorKind::report_code_block_limit(
            code_blocks.to_string(),
            REPORT_CODE_BLOCK_LIMIT.to_string(),
        )
        .into());
    }

    println!("report is compact enough");
    Ok(0)
}

fn report_group(
    group_id: &str,
    status: &str,
    evidence: &[String],
    evidence_label: &[String],
    capture_label: Option<&str>,
    note: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let run_dir = resolve_run_dir(run_dir_args)?;

    if evidence.is_empty() && evidence_label.is_empty() && capture_label.is_none() {
        return Err(CliErrorKind::ReportGroupEvidenceRequired.into());
    }

    let ctx = RunContext::from_run_dir(&run_dir)?;

    let Some(mut run_status) = ctx.status else {
        return Err(CliErrorKind::MissingRunStatus.into());
    };

    let verdict: GroupVerdict = status.parse().map_err(|()| {
        CliErrorKind::usage_error(format!(
            "unknown group status '{status}': must be pass, fail, or skip"
        ))
    })?;

    let now = utc_now();
    let existing_verdict = run_status.group_verdict(group_id);
    let state_capture_at_report = run_status.last_state_capture.clone();

    if let Some(previous) = existing_verdict {
        if previous == verdict {
            // Same status reported again - silently succeed for idempotency.
            return Ok(0);
        }
        // Different status - update the entry and adjust counts.
        eprintln!("group {group_id} status updated from {previous} to {verdict}");
    } else {
        // Warn if no state capture happened since the last group report.
        // The capture_label flag on this command triggers an inline capture,
        // so only warn when that flag is also absent.
        if capture_label.is_none() {
            warn_if_capture_missing(&run_status);
        }
    }
    let change = run_status.record_group_result(group_id, verdict, &now, state_capture_at_report);
    run_status.last_completed_group = Some(group_id.to_string());
    run_status.last_updated_utc = Some(now.clone());
    debug_assert_ne!(change, ExecutedGroupChange::Noop);

    if let Some(n) = note {
        run_status.notes.push(n.to_string());
    }

    // Write report section first so status is never updated if report fails.
    let mut report = RunReport::from_markdown(&ctx.layout.report_path())?;

    let mut section = format!("\n## Group: {group_id}\n\n**Verdict:** {verdict}\n");
    let all_refs: Vec<&str> = evidence
        .iter()
        .map(String::as_str)
        .chain(evidence_label.iter().map(String::as_str))
        .chain(capture_label)
        .collect();
    if !all_refs.is_empty() {
        let _ = write!(section, "\n**Evidence:** {}\n", all_refs.join(", "));
    }
    if let Some(n) = note {
        let _ = write!(section, "\n**Note:** {n}\n");
    }

    report.body.push_str(&section);
    report.save()?;

    write_run_status_with_audit(
        &ctx.layout.run_dir(),
        &run_status,
        None,
        Some("execution"),
        Some(group_id),
    )?;

    // Auto-advance runner state from bootstrap/preflight to execution when
    // a group result is recorded.
    ensure_execution_phase(&run_dir)?;

    Ok(0)
}

/// Emit a warning when no state capture happened between the previous group
/// report and the current one. Compares `last_state_capture` against the
/// capture value recorded at the time of the most recent group entry.
fn warn_if_capture_missing(run_status: &RunStatus) {
    // No previous group means this is the first group - no between-group
    // capture obligation exists yet.
    if run_status.last_completed_group.is_none() {
        return;
    }

    let previous_capture = run_status.last_group_capture_value();
    let current_capture = run_status.last_state_capture.as_deref();

    // If the capture value is the same as when the previous group was
    // reported, no standalone capture happened in between.
    if current_capture == previous_capture {
        eprintln!(
            "warning: no state capture between group '{}' and this group - \
             run 'harness capture' or pass --capture-label to preserve state snapshots",
            run_status
                .last_completed_group
                .as_deref()
                .unwrap_or("unknown"),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::{ExecutedGroupRecord, RunCounts, Verdict};

    fn make_status() -> RunStatus {
        RunStatus {
            run_id: "test-run".to_string(),
            suite_id: "test-suite".to_string(),
            profile: "default".to_string(),
            started_at: "2026-03-16T00:00:00Z".to_string(),
            overall_verdict: Verdict::Pending,
            completed_at: None,
            counts: RunCounts::default(),
            executed_groups: vec![],
            skipped_groups: vec![],
            last_completed_group: None,
            last_state_capture: None,
            last_updated_utc: None,
            next_planned_group: None,
            notes: vec![],
        }
    }

    #[test]
    fn last_group_capture_value_empty_groups() {
        let status = make_status();
        assert_eq!(status.last_group_capture_value(), None);
    }

    #[test]
    fn last_group_capture_value_with_capture() {
        let mut status = make_status();
        status.executed_groups = vec![ExecutedGroupRecord {
            group_id: "g01".to_string(),
            verdict: GroupVerdict::Pass,
            completed_at: "2026-03-16T00:00:00Z".to_string(),
            state_capture_at_report: Some("state/after-g01.json".to_string()),
        }];
        assert_eq!(
            status.last_group_capture_value(),
            Some("state/after-g01.json")
        );
    }

    #[test]
    fn last_group_capture_value_null_capture() {
        let mut status = make_status();
        status.executed_groups = vec![ExecutedGroupRecord {
            group_id: "g01".to_string(),
            verdict: GroupVerdict::Pass,
            completed_at: "2026-03-16T00:00:00Z".to_string(),
            state_capture_at_report: None,
        }];
        assert_eq!(status.last_group_capture_value(), None);
    }

    #[test]
    fn warn_if_capture_missing_no_previous_group() {
        let status = make_status();
        // Should not panic - first group has no obligation.
        warn_if_capture_missing(&status);
    }

    #[test]
    fn warn_if_capture_missing_capture_unchanged() {
        let mut status = make_status();
        status.last_completed_group = Some("g01".to_string());
        status.last_state_capture = Some("state/capture-1.json".to_string());
        status.executed_groups = vec![ExecutedGroupRecord {
            group_id: "g01".to_string(),
            verdict: GroupVerdict::Pass,
            completed_at: "2026-03-16T00:00:00Z".to_string(),
            state_capture_at_report: Some("state/capture-1.json".to_string()),
        }];
        // Capture unchanged since g01 - should warn (captured in stderr).
        warn_if_capture_missing(&status);
    }

    #[test]
    fn warn_if_capture_missing_capture_changed() {
        let mut status = make_status();
        status.last_completed_group = Some("g01".to_string());
        status.last_state_capture = Some("state/capture-2.json".to_string());
        status.executed_groups = vec![ExecutedGroupRecord {
            group_id: "g01".to_string(),
            verdict: GroupVerdict::Pass,
            completed_at: "2026-03-16T00:00:00Z".to_string(),
            state_capture_at_report: Some("state/capture-1.json".to_string()),
        }];
        // Capture changed since g01 - should not warn.
        warn_if_capture_missing(&status);
    }
}
