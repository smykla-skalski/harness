use serde_json::Value;

use crate::daemon::protocol::http_paths;
use crate::task_board::{
    TaskBoardAiReviewReportRecord, TaskBoardAiReviewReportStatus, TaskBoardReportOnlyReviewFinding,
    TaskBoardReviewFindingLocation, TaskBoardReviewFindingSeverity,
};

use super::remote_viewer_support::get_http_json;
use crate::daemon::db::task_board::prelude::*;

pub(super) async fn seed_review_report(
    state: &crate::daemon::http::DaemonHttpState,
    item_id: &str,
) {
    state
        .async_db
        .get()
        .expect("async db")
        .append_task_board_ai_review_report(&review_report(item_id))
        .await
        .expect("seed review report");
}

pub(super) async fn assert_http_review_report(
    client: &reqwest::Client,
    base_url: &str,
    item_id: &str,
    client_id: &str,
    redacted: bool,
) {
    let report = get_http_json(
        client,
        base_url,
        &http_paths::TASK_BOARD_ITEM_REVIEW_REPORT.replace("{item_id}", item_id),
        client_id,
    )
    .await;
    assert_review_report(&report, redacted);
}

fn assert_review_report(response: &Value, redacted: bool) {
    let expected = if redacted {
        "[redacted]"
    } else {
        "Review content visible to operators"
    };
    assert_eq!(response["status"], "completed");
    assert_eq!(response["report"]["summary"], expected);
    assert_eq!(
        response["report"]["findings"][0]["location"]["path"],
        expected
    );
    assert_eq!(response["report"]["findings"][0]["evidence"], expected);
    assert_eq!(response["report"]["partial_output"], expected);
}

fn review_report(item_id: &str) -> TaskBoardAiReviewReportRecord {
    let content = "Review content visible to operators".to_string();
    TaskBoardAiReviewReportRecord {
        report_id: "remote-viewer-report".into(),
        item_id: item_id.into(),
        correlation_id: "remote-viewer-correlation".into(),
        repository: "example/harness".into(),
        pull_request_number: 42,
        head_revision: "0123456789abcdef0123456789abcdef01234567".into(),
        runtime: "openrouter".into(),
        requested_runtime: "openrouter".into(),
        actual_runtime: Some("openrouter".into()),
        requested_model: "deepseek/deepseek-v4-flash".into(),
        effective_model: Some("deepseek/deepseek-v4-flash".into()),
        status: TaskBoardAiReviewReportStatus::Completed,
        summary: Some(content.clone()),
        findings: vec![TaskBoardReportOnlyReviewFinding {
            severity: TaskBoardReviewFindingSeverity::High,
            location: TaskBoardReviewFindingLocation {
                path: content.clone(),
                line: Some(42),
            },
            evidence: content.clone(),
        }],
        partial_output: Some(content),
        terminal_reason: None,
        started_at: "2026-07-29T18:00:00Z".into(),
        finished_at: "2026-07-29T18:00:01Z".into(),
    }
}
