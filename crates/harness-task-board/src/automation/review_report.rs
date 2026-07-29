use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::report_only_review::{
    TaskBoardReportOnlyReviewError, TaskBoardReportOnlyReviewFinding, validate_finding_path,
    validate_head_revision, validate_nonempty,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardAiReviewReportStatus {
    Completed,
    Failed,
    Cancelled,
}

impl TaskBoardAiReviewReportStatus {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Cancelled => "cancelled",
        }
    }

    /// Parse one durable terminal status label.
    ///
    /// # Errors
    /// Returns an error for an unknown status.
    pub fn parse(value: &str) -> Result<Self, TaskBoardAiReviewReportError> {
        match value {
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            "cancelled" => Ok(Self::Cancelled),
            _ => Err(TaskBoardAiReviewReportError::InvalidStatus),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, utoipa::ToSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskBoardAiReviewReportRecord {
    pub report_id: String,
    pub item_id: String,
    pub correlation_id: String,
    pub repository: String,
    pub pull_request_number: u64,
    pub head_revision: String,
    pub runtime: String,
    pub requested_model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effective_model: Option<String>,
    pub status: TaskBoardAiReviewReportStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub summary: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub findings: Vec<TaskBoardReportOnlyReviewFinding>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partial_output: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_reason: Option<String>,
    pub started_at: String,
    pub finished_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum TaskBoardAiReviewReportError {
    #[error(transparent)]
    InvalidReview(#[from] TaskBoardReportOnlyReviewError),
    #[error("AI review pull request number must be greater than zero")]
    InvalidPullRequestNumber,
    #[error("AI review report status is invalid")]
    InvalidStatus,
    #[error("AI review report timestamps must be RFC 3339 and finish no earlier than start")]
    InvalidTimestamps,
    #[error("completed AI review reports require a summary and forbid a terminal reason")]
    InvalidCompletedState,
    #[error("failed or cancelled AI review reports require a terminal reason")]
    InvalidFailureState,
}

/// Validate one append-only terminal report before persistence.
///
/// # Errors
/// Returns an error when identity, provenance, output, or terminal state is invalid.
pub fn validate_task_board_ai_review_report(
    report: &TaskBoardAiReviewReportRecord,
) -> Result<(), TaskBoardAiReviewReportError> {
    for (field, value) in [
        ("report_id", report.report_id.as_str()),
        ("item_id", report.item_id.as_str()),
        ("correlation_id", report.correlation_id.as_str()),
        ("repository", report.repository.as_str()),
        ("runtime", report.runtime.as_str()),
        ("requested_model", report.requested_model.as_str()),
    ] {
        validate_nonempty(field, value)?;
    }
    if report.pull_request_number == 0 {
        return Err(TaskBoardAiReviewReportError::InvalidPullRequestNumber);
    }
    validate_head_revision(&report.head_revision)?;
    validate_optional_output(report)?;
    validate_timestamps(report)?;
    validate_terminal_state(report)
}

fn validate_optional_output(
    report: &TaskBoardAiReviewReportRecord,
) -> Result<(), TaskBoardAiReviewReportError> {
    if let Some(model) = report.effective_model.as_deref() {
        validate_nonempty("effective_model", model)?;
    }
    if let Some(summary) = report.summary.as_deref() {
        validate_nonempty("summary", summary)?;
    }
    if let Some(partial_output) = report.partial_output.as_deref() {
        validate_nonempty("partial_output", partial_output)?;
    }
    for finding in &report.findings {
        validate_finding_path(&finding.location.path)?;
        validate_nonempty("finding.evidence", &finding.evidence)?;
        if finding.location.line == Some(0) {
            return Err(TaskBoardReportOnlyReviewError::InvalidFindingLine.into());
        }
    }
    Ok(())
}

fn validate_timestamps(
    report: &TaskBoardAiReviewReportRecord,
) -> Result<(), TaskBoardAiReviewReportError> {
    let started = report.started_at.parse::<DateTime<Utc>>();
    let finished = report.finished_at.parse::<DateTime<Utc>>();
    match (started, finished) {
        (Ok(started), Ok(finished)) if finished >= started => Ok(()),
        _ => Err(TaskBoardAiReviewReportError::InvalidTimestamps),
    }
}

fn validate_terminal_state(
    report: &TaskBoardAiReviewReportRecord,
) -> Result<(), TaskBoardAiReviewReportError> {
    match report.status {
        TaskBoardAiReviewReportStatus::Completed
            if report.summary.is_some() && report.terminal_reason.is_none() =>
        {
            Ok(())
        }
        TaskBoardAiReviewReportStatus::Completed => {
            Err(TaskBoardAiReviewReportError::InvalidCompletedState)
        }
        TaskBoardAiReviewReportStatus::Failed | TaskBoardAiReviewReportStatus::Cancelled
            if report
                .terminal_reason
                .as_deref()
                .is_some_and(|reason| !reason.trim().is_empty()) =>
        {
            Ok(())
        }
        TaskBoardAiReviewReportStatus::Failed | TaskBoardAiReviewReportStatus::Cancelled => {
            Err(TaskBoardAiReviewReportError::InvalidFailureState)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{TaskBoardReviewFindingLocation, TaskBoardReviewFindingSeverity};

    #[test]
    fn completed_report_keeps_full_provenance_and_findings() {
        let report = completed_report();

        validate_task_board_ai_review_report(&report).expect("valid completed report");
        assert_eq!(report.status.as_str(), "completed");
        assert_eq!(
            TaskBoardAiReviewReportStatus::parse("cancelled").expect("known status"),
            TaskBoardAiReviewReportStatus::Cancelled
        );
    }

    #[test]
    fn terminal_state_and_chronology_fail_closed() {
        let mut report = completed_report();
        report.summary = None;
        assert_eq!(
            validate_task_board_ai_review_report(&report),
            Err(TaskBoardAiReviewReportError::InvalidCompletedState)
        );

        report.status = TaskBoardAiReviewReportStatus::Failed;
        assert_eq!(
            validate_task_board_ai_review_report(&report),
            Err(TaskBoardAiReviewReportError::InvalidFailureState)
        );

        report.terminal_reason = Some("provider rejected the request".into());
        report.started_at = "2026-07-29T16:00:01Z".into();
        report.finished_at = "2026-07-29T16:00:00Z".into();
        assert_eq!(
            validate_task_board_ai_review_report(&report),
            Err(TaskBoardAiReviewReportError::InvalidTimestamps)
        );
    }

    fn completed_report() -> TaskBoardAiReviewReportRecord {
        TaskBoardAiReviewReportRecord {
            report_id: "report-1".into(),
            item_id: "ticket-899".into(),
            correlation_id: "turn-1".into(),
            repository: "smykla-skalski/harness".into(),
            pull_request_number: 1122,
            head_revision: "0123456789abcdef0123456789abcdef01234567".into(),
            runtime: "openrouter".into(),
            requested_model: "deepseek/deepseek-v4-flash".into(),
            effective_model: Some("deepseek/deepseek-v4-flash".into()),
            status: TaskBoardAiReviewReportStatus::Completed,
            summary: Some("One actionable defect.".into()),
            findings: vec![TaskBoardReportOnlyReviewFinding {
                severity: TaskBoardReviewFindingSeverity::High,
                location: TaskBoardReviewFindingLocation {
                    path: "src/lib.rs".into(),
                    line: Some(41),
                },
                evidence: "The new branch skips validation.".into(),
            }],
            partial_output: None,
            terminal_reason: None,
            started_at: "2026-07-29T16:00:00Z".into(),
            finished_at: "2026-07-29T16:00:01Z".into(),
        }
    }
}
