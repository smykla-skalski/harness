use crate::task_board::{TaskBoardAiReviewReportRecord, TaskBoardAiReviewReportResponse};

use super::super::remote_redaction::REDACTION_PLACEHOLDER;

#[must_use]
pub(crate) fn project_task_board_ai_review_report(
    response: TaskBoardAiReviewReportResponse,
    viewer: bool,
) -> TaskBoardAiReviewReportResponse {
    if !viewer {
        return response;
    }
    match response {
        TaskBoardAiReviewReportResponse::Completed { report } => {
            TaskBoardAiReviewReportResponse::Completed {
                report: redact_report(report),
            }
        }
        TaskBoardAiReviewReportResponse::Failed { report } => {
            TaskBoardAiReviewReportResponse::Failed {
                report: redact_report(report),
            }
        }
        TaskBoardAiReviewReportResponse::Cancelled { report } => {
            TaskBoardAiReviewReportResponse::Cancelled {
                report: redact_report(report),
            }
        }
        response => response,
    }
}

fn redact_report(mut report: TaskBoardAiReviewReportRecord) -> TaskBoardAiReviewReportRecord {
    report.summary = report
        .summary
        .map(|_| REDACTION_PLACEHOLDER.to_string());
    for finding in &mut report.findings {
        finding.location.path = REDACTION_PLACEHOLDER.to_string();
        finding.evidence = REDACTION_PLACEHOLDER.to_string();
    }
    report.partial_output = report
        .partial_output
        .map(|_| REDACTION_PLACEHOLDER.to_string());
    report.terminal_reason = report
        .terminal_reason
        .map(|_| REDACTION_PLACEHOLDER.to_string());
    report
}

#[cfg(test)]
mod tests {
    use crate::task_board::{
        TaskBoardAiReviewReportRecord, TaskBoardAiReviewReportResponse,
        TaskBoardAiReviewReportStatus, TaskBoardReportOnlyReviewFinding,
        TaskBoardReviewFindingLocation, TaskBoardReviewFindingSeverity,
    };

    use super::project_task_board_ai_review_report;

    #[test]
    fn remote_viewer_report_replaces_all_review_content() {
        let projected = project_task_board_ai_review_report(completed_report(), true);
        let TaskBoardAiReviewReportResponse::Completed { report } = projected else {
            panic!("expected completed report");
        };

        assert_eq!(report.summary.as_deref(), Some("[redacted]"));
        assert_eq!(report.findings[0].location.path, "[redacted]");
        assert_eq!(report.findings[0].evidence, "[redacted]");
        assert_eq!(report.partial_output.as_deref(), Some("[redacted]"));
    }

    #[test]
    fn remote_viewer_terminal_reason_is_replaced() {
        let TaskBoardAiReviewReportResponse::Completed { mut report } = completed_report() else {
            panic!("expected completed report");
        };
        report.status = TaskBoardAiReviewReportStatus::Failed;
        report.summary = None;
        report.findings.clear();
        report.partial_output = None;
        report.terminal_reason = Some("ordinary terminal reason".into());

        let projected = project_task_board_ai_review_report(
            TaskBoardAiReviewReportResponse::Completed { report },
            true,
        );
        let TaskBoardAiReviewReportResponse::Completed { report } = projected else {
            panic!("expected failed report");
        };
        assert_eq!(report.terminal_reason.as_deref(), Some("[redacted]"));
    }

    fn completed_report() -> TaskBoardAiReviewReportResponse {
        TaskBoardAiReviewReportResponse::Completed {
            report: TaskBoardAiReviewReportRecord {
                report_id: "report-1".into(),
                item_id: "item-1".into(),
                correlation_id: "run-1".into(),
                repository: "example/repo".into(),
                pull_request_number: 17,
                head_revision: "0123456789abcdef0123456789abcdef01234567".into(),
                runtime: "openrouter".into(),
                requested_model: "deepseek/deepseek-v4-flash".into(),
                effective_model: None,
                status: TaskBoardAiReviewReportStatus::Completed,
                summary: Some("ordinary review summary".into()),
                findings: vec![TaskBoardReportOnlyReviewFinding {
                    severity: TaskBoardReviewFindingSeverity::High,
                    location: TaskBoardReviewFindingLocation {
                        path: "src/private.rs".into(),
                        line: Some(1),
                    },
                    evidence: "ordinary review evidence".into(),
                }],
                partial_output: Some("ordinary partial output".into()),
                terminal_reason: None,
                started_at: "2026-07-29T18:00:00Z".into(),
                finished_at: "2026-07-29T18:00:01Z".into(),
            },
        }
    }
}
