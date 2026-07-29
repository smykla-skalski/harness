use crate::task_board::{TaskBoardAiReviewReportRecord, TaskBoardAiReviewReportResponse};

use super::super::remote_redaction::redact_known_secrets;

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
    report.summary = report.summary.map(|value| redact_known_secrets(&value));
    for finding in &mut report.findings {
        finding.location.path = redact_known_secrets(&finding.location.path);
        finding.evidence = redact_known_secrets(&finding.evidence);
    }
    report.partial_output = report
        .partial_output
        .map(|value| redact_known_secrets(&value));
    report.terminal_reason = report
        .terminal_reason
        .map(|value| redact_known_secrets(&value));
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
    fn remote_viewer_report_redacts_free_text_and_finding_paths() {
        let projected = project_task_board_ai_review_report(completed_report(), true);
        let TaskBoardAiReviewReportResponse::Completed { report } = projected else {
            panic!("expected completed report");
        };

        let wire = serde_json::to_string(&report).expect("serialize projected report");
        assert!(!wire.contains("secret-value"));
        assert_eq!(wire.matches("[redacted]").count(), 4);
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
                summary: Some("token=secret-value".into()),
                findings: vec![TaskBoardReportOnlyReviewFinding {
                    severity: TaskBoardReviewFindingSeverity::High,
                    location: TaskBoardReviewFindingLocation {
                        path: "token=secret-value".into(),
                        line: Some(1),
                    },
                    evidence: "token=secret-value".into(),
                }],
                partial_output: Some("token=secret-value".into()),
                terminal_reason: None,
                started_at: "2026-07-29T18:00:00Z".into(),
                finished_at: "2026-07-29T18:00:01Z".into(),
            },
        }
    }
}
