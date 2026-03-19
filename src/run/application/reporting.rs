use std::path::PathBuf;

use crate::errors::{CliError, CliErrorKind};
use crate::run::RunReport;
use crate::run::report_policy::{REPORT_CODE_BLOCK_LIMIT, REPORT_LINE_LIMIT};
use crate::run::services::ReportCheckOutcome;

use super::RunApplication;

/// Check report compactness, resolving the active run report by default.
///
/// # Errors
/// Returns `CliError` when the report cannot be loaded or exceeds compactness limits.
pub(crate) fn check_report_compactness(
    report_path: Option<&str>,
) -> Result<ReportCheckOutcome, CliError> {
    let path = resolve_report_path(report_path)?;
    if !path.exists() {
        return Ok(ReportCheckOutcome::Missing);
    }

    let report = RunReport::from_markdown(&path)?;
    let body = report.to_markdown();
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

    Ok(ReportCheckOutcome::Valid)
}

fn resolve_report_path(report_path: Option<&str>) -> Result<PathBuf, CliError> {
    if let Some(path) = report_path {
        return Ok(PathBuf::from(path));
    }

    let run = RunApplication::from_current()?
        .ok_or_else(|| -> CliError { CliErrorKind::missing_run_context_value("report").into() })?;
    Ok(run.layout().report_path())
}
