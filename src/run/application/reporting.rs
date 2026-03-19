use std::fmt::Write as _;
use std::path::PathBuf;

use crate::errors::{CliError, CliErrorKind};
use crate::run::audit::write_run_status_with_audit;
use crate::run::report_policy::{REPORT_CODE_BLOCK_LIMIT, REPORT_LINE_LIMIT};
use crate::run::services::reporting::apply_group_report_result;
use crate::run::workflow::ensure_execution_phase;
use crate::run::{GroupVerdict, RunReport};

use super::RunApplication;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReportCheckOutcome {
    Missing,
    Valid,
}

#[derive(Debug, Clone)]
pub struct GroupReportRequest<'a> {
    pub group_id: &'a str,
    pub verdict: GroupVerdict,
    pub evidence: &'a [String],
    pub evidence_label: &'a [String],
    pub capture_label: Option<&'a str>,
    pub note: Option<&'a str>,
}

impl RunApplication {
    /// Persist a completed group verdict into the tracked run report and status.
    ///
    /// # Errors
    /// Returns `CliError` on status/report persistence failures.
    pub fn finalize_group_report(
        &mut self,
        request: &GroupReportRequest<'_>,
    ) -> Result<(), CliError> {
        if request.evidence.is_empty()
            && request.evidence_label.is_empty()
            && request.capture_label.is_none()
        {
            return Err(CliErrorKind::ReportGroupEvidenceRequired.into());
        }

        let run_dir = self.layout().run_dir();
        let report_path = self.layout().report_path();
        let Some(run_status) = self.status_mut() else {
            return Err(CliErrorKind::MissingRunStatus.into());
        };

        if !apply_group_report_result(
            run_status,
            request.group_id,
            request.verdict,
            request.capture_label,
            request.note,
        ) {
            return Ok(());
        }

        let mut report = RunReport::from_markdown(&report_path)?;
        let mut section = format!(
            "\n## Group: {}\n\n**Verdict:** {}\n",
            request.group_id, request.verdict
        );
        let all_refs: Vec<&str> = request
            .evidence
            .iter()
            .map(String::as_str)
            .chain(request.evidence_label.iter().map(String::as_str))
            .chain(request.capture_label)
            .collect();
        if !all_refs.is_empty() {
            let _ = write!(section, "\n**Evidence:** {}\n", all_refs.join(", "));
        }
        if let Some(note) = request.note {
            let _ = write!(section, "\n**Note:** {note}\n");
        }

        report.body.push_str(&section);
        report.save()?;
        write_run_status_with_audit(
            &run_dir,
            run_status,
            None,
            Some("execution"),
            Some(request.group_id),
        )?;
        ensure_execution_phase(&run_dir)?;
        Ok(())
    }
}

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
