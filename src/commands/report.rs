use std::path::PathBuf;

use crate::cli::{ReportCommand, RunDirArgs};
use crate::context::{RunContext, RunLookup};
use crate::errors::{CliError, CliErrorKind};
use crate::resolve::resolve_run_directory;
use crate::rules::suite_runner::{REPORT_CODE_BLOCK_LIMIT, REPORT_LINE_LIMIT};
use crate::schema::RunReport;

/// Report validation and group finalization.
///
/// # Errors
/// Returns `CliError` on failure.
pub fn execute(cmd: &ReportCommand) -> Result<i32, CliError> {
    match cmd {
        ReportCommand::Check { report } => run_check(report.as_deref()),
        ReportCommand::Group {
            group_id,
            status,
            evidence,
            evidence_label,
            capture_label,
            note,
            run_dir,
        } => run_group(
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

fn run_check(report_path: Option<&str>) -> Result<i32, CliError> {
    let path = report_path.map(PathBuf::from).ok_or_else(|| -> CliError {
        CliErrorKind::MissingRunContextValue {
            field: "report".into(),
        }
        .into()
    })?;

    let report = RunReport::from_markdown(&path)?;
    let body = report.to_markdown();
    let line_count = body.lines().count();
    let code_blocks = body.matches("```").count() / 2;

    if line_count > REPORT_LINE_LIMIT {
        return Err(CliErrorKind::ReportLineLimit {
            count: line_count.to_string().into(),
            limit: REPORT_LINE_LIMIT.to_string().into(),
        }
        .into());
    }
    if code_blocks > REPORT_CODE_BLOCK_LIMIT {
        return Err(CliErrorKind::ReportCodeBlockLimit {
            count: code_blocks.to_string().into(),
            limit: REPORT_CODE_BLOCK_LIMIT.to_string().into(),
        }
        .into());
    }

    println!("report is compact enough");
    Ok(0)
}

fn run_group(
    _group_id: &str,
    _status: &str,
    evidence: &[String],
    evidence_label: &[String],
    capture_label: Option<&str>,
    _note: Option<&str>,
    run_dir_args: &RunDirArgs,
) -> Result<i32, CliError> {
    let lookup = RunLookup {
        run_dir: run_dir_args.run_dir.clone(),
        run_id: run_dir_args.run_id.clone(),
        run_root: run_dir_args.run_root.clone(),
    };

    let run_dir = resolve_run_directory(&lookup)?.run_dir;

    if evidence.is_empty() && evidence_label.is_empty() && capture_label.is_none() {
        return Err(CliErrorKind::ReportGroupEvidenceRequired.into());
    }

    let ctx = RunContext::from_run_dir(&run_dir)?;
    // TODO: implement actual report update
    eprintln!(
        "stub: would update {} and {}",
        ctx.layout.status_path().display(),
        ctx.layout.report_path().display()
    );
    println!(
        "stub: would update {} and {}",
        ctx.layout.status_path().display(),
        ctx.layout.report_path().display()
    );
    Ok(0)
}
