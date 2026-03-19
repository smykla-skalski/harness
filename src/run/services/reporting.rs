use std::fmt::Write as _;
use std::path::PathBuf;

use tracing::warn;

use crate::errors::{CliError, CliErrorKind};
use crate::run::report_policy::{REPORT_CODE_BLOCK_LIMIT, REPORT_LINE_LIMIT};
use crate::run::audit::write_run_status_with_audit;
use crate::run::workflow::ensure_execution_phase;
use crate::schema::{ExecutedGroupChange, GroupVerdict, RunReport, RunStatus};
use crate::workspace::utc_now;

use super::RunServices;

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

/// Check report compactness, resolving the active run report by default.
///
/// # Errors
/// Returns `CliError` when the report cannot be loaded or exceeds compactness limits.
pub fn check_report_compactness(report_path: Option<&str>) -> Result<ReportCheckOutcome, CliError> {
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

impl RunServices {
    /// Persist a completed group verdict into the tracked run report and status.
    ///
    /// Returns `Ok(true)` when state changed and `Ok(false)` for an idempotent update.
    ///
    /// # Errors
    /// Returns `CliError` on status/report persistence failures.
    pub fn finalize_group_report(
        &mut self,
        request: &GroupReportRequest<'_>,
    ) -> Result<bool, CliError> {
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
            return Ok(false);
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
        Ok(true)
    }
}

fn resolve_report_path(report_path: Option<&str>) -> Result<PathBuf, CliError> {
    if let Some(path) = report_path {
        return Ok(PathBuf::from(path));
    }

    let services = RunServices::from_current()?
        .ok_or_else(|| -> CliError { CliErrorKind::missing_run_context_value("report").into() })?;
    Ok(services.layout().report_path())
}

fn apply_group_report_result(
    run_status: &mut RunStatus,
    group_id: &str,
    verdict: GroupVerdict,
    capture_label: Option<&str>,
    note: Option<&str>,
) -> bool {
    let state_capture_at_report = run_status.last_state_capture.take();

    if !prepare_group_report_update(
        run_status,
        group_id,
        verdict,
        capture_label,
        state_capture_at_report.as_deref(),
    ) {
        run_status.last_state_capture = state_capture_at_report;
        return false;
    }

    let now = utc_now();
    let change =
        run_status.record_group_result(group_id, verdict, &now, state_capture_at_report.as_deref());
    run_status.last_completed_group = Some(group_id.to_string());
    run_status.last_updated_utc = Some(now);
    run_status.last_state_capture = state_capture_at_report;
    debug_assert_ne!(change, ExecutedGroupChange::Noop);

    if let Some(note) = note {
        run_status.notes.push(note.to_string());
    }

    true
}

fn prepare_group_report_update(
    run_status: &RunStatus,
    group_id: &str,
    verdict: GroupVerdict,
    capture_label: Option<&str>,
    state_capture_at_report: Option<&str>,
) -> bool {
    match run_status.group_verdict(group_id) {
        Some(previous) if previous == verdict => false,
        Some(previous) => {
            warn!(%group_id, %previous, %verdict, "group status updated");
            true
        }
        None => {
            if capture_label.is_none() {
                warn_if_capture_missing_with_state(run_status, state_capture_at_report);
            }
            true
        }
    }
}

fn warn_if_capture_missing_with_state(run_status: &RunStatus, last_state_capture: Option<&str>) {
    if run_status.last_completed_group.is_none() {
        return;
    }

    if last_state_capture == run_status.last_group_capture_value() {
        let previous_group = run_status
            .last_completed_group
            .as_deref()
            .unwrap_or("unknown");
        warn!(
            %previous_group,
            "no state capture between groups - run 'harness run capture' or pass --capture-label"
        );
    }
}

#[cfg(test)]
mod tests {
    use crate::schema::{ExecutedGroupRecord, RunCounts, Verdict};

    use super::*;

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
        warn_if_capture_missing_with_state(&status, None);
    }

    #[test]
    fn warn_if_capture_missing_capture_unchanged() {
        let mut status = make_status();
        status.last_completed_group = Some("g01".to_string());
        status.executed_groups = vec![ExecutedGroupRecord {
            group_id: "g01".to_string(),
            verdict: GroupVerdict::Pass,
            completed_at: "2026-03-16T00:00:00Z".to_string(),
            state_capture_at_report: Some("state/capture-1.json".to_string()),
        }];
        warn_if_capture_missing_with_state(&status, Some("state/capture-1.json"));
    }

    #[test]
    fn warn_if_capture_missing_capture_changed() {
        let mut status = make_status();
        status.last_completed_group = Some("g01".to_string());
        status.executed_groups = vec![ExecutedGroupRecord {
            group_id: "g01".to_string(),
            verdict: GroupVerdict::Pass,
            completed_at: "2026-03-16T00:00:00Z".to_string(),
            state_capture_at_report: Some("state/capture-1.json".to_string()),
        }];
        warn_if_capture_missing_with_state(&status, Some("state/capture-2.json"));
    }
}
