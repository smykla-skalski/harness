use reqwest::StatusCode;
use serde_json::{Value, json};
use tempfile::tempdir;

use crate::daemon::protocol::{http_paths, ws_methods};
use crate::task_board::{TaskBoardAiReviewReportRecord, TaskBoardAiReviewReportStatus};

use super::task_board_review_report_support::{
    seed_running_execution, settle_active_review_attempt,
};
use crate::daemon::db::task_board::prelude::*;

mod review_freshness;
mod transport_support;
mod work_item_progress;
mod workflow_progress;

use transport_support::*;

#[test]
fn task_board_http_and_ws_item_payloads_and_errors_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_transport_parity());
    });
}

async fn run_task_board_transport_parity() {
    let state = super::test_http_state_with_db();
    let db = state.async_db.get().expect("test async database").clone();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let shared_payload = json!({
        "title": "Transport parity item",
        "body": "Shared task-board body",
        "priority": "high",
        "agent_mode": "planning",
        "tags": ["parity"],
        "project_id": "project-alpha",
        "planning": {
            "summary": "Shared planning summary"
        },
        "workflow": {
            "status": "running",
            "branch": "feature/parity",
            "pr_head_revision": "0123456789abcdef0123456789abcdef01234567"
        }
    });

    let mut http_payload = shared_payload.clone();
    http_payload["id"] = json!("parity-http");
    let http_item = post_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ITEMS,
        http_payload,
    )
    .await;

    let mut ws_payload = shared_payload;
    ws_payload["id"] = json!("parity-ws");
    let ws_item = ws_rpc(
        &base_url,
        "req-task-board-create",
        ws_methods::TASK_BOARD_CREATE,
        ws_payload,
    )
    .await;

    assert_eq!(
        normalized_item(&http_item),
        normalized_item(&ws_item["result"])
    );

    let http_list = get_json(
        &client,
        &base_url,
        &format!("{}?status=todo", http_paths::TASK_BOARD_ITEMS),
    )
    .await;
    let ws_list = ws_result(
        &base_url,
        "req-task-board-list",
        ws_methods::TASK_BOARD_LIST,
        json!({ "status": "todo" }),
    )
    .await;
    assert_eq!(http_list, ws_list);

    let http_loaded = get_json(&client, &base_url, "/v1/task-board/items/parity-http").await;
    let ws_loaded = ws_result(
        &base_url,
        "req-task-board-get",
        ws_methods::TASK_BOARD_GET,
        json!({ "id": "parity-ws" }),
    )
    .await;
    assert_eq!(normalized_item(&http_loaded), normalized_item(&ws_loaded));

    let http_review = get_json(
        &client,
        &base_url,
        "/v1/task-board/items/parity-http/review-report",
    )
    .await;
    let ws_review = ws_result(
        &base_url,
        "req-task-board-review-report-not-started",
        ws_methods::TASK_BOARD_REVIEW_REPORT_GET,
        json!({ "id": "parity-ws" }),
    )
    .await;
    assert_eq!(http_review, json!({ "status": "not_started" }));
    assert_eq!(http_review, ws_review);
    workflow_progress::assert_not_started(&client, &base_url).await;
    work_item_progress::assert_not_dispatched(&client, &base_url).await;
    work_item_progress::link_work_items(&db).await;
    work_item_progress::assert_report_and_read_agree(&client, &base_url).await;
    work_item_progress::assert_missing_error(&client, &base_url).await;

    let http_execution = seed_running_execution(&db, "parity-http").await;
    let ws_execution = seed_running_execution(&db, "parity-ws").await;
    db.append_task_board_ai_review_report(&completed_report("parity-http"))
        .await
        .expect("append older HTTP review report");
    db.append_task_board_ai_review_report(&completed_report("parity-ws"))
        .await
        .expect("append older WebSocket review report");
    let http_review = get_json(
        &client,
        &base_url,
        "/v1/task-board/items/parity-http/review-report",
    )
    .await;
    let ws_review = ws_result(
        &base_url,
        "req-task-board-review-report-running",
        ws_methods::TASK_BOARD_REVIEW_REPORT_GET,
        json!({ "id": "parity-ws" }),
    )
    .await;
    assert_eq!(
        normalized_running_review(&http_review),
        normalized_running_review(&ws_review)
    );
    assert_eq!(http_review["status"], "running");
    assert_eq!(http_review["runtime"], "openrouter");
    assert_eq!(http_review["requested_model"], "deepseek/deepseek-v4-flash");
    assert_eq!(
        http_review["head_revision"],
        "0123456789abcdef0123456789abcdef01234567"
    );
    assert_eq!(http_review["started_at"], "2026-07-29T18:00:05Z");
    workflow_progress::assert_running(&client, &base_url).await;
    settle_active_review_attempt(&db, &http_execution).await;
    settle_active_review_attempt(&db, &ws_execution).await;

    let http_review = get_json(
        &client,
        &base_url,
        "/v1/task-board/items/parity-http/review-report",
    )
    .await;
    let ws_review = ws_result(
        &base_url,
        "req-task-board-review-report-completed",
        ws_methods::TASK_BOARD_REVIEW_REPORT_GET,
        json!({ "id": "parity-ws" }),
    )
    .await;
    assert_eq!(
        normalized_review(&http_review),
        normalized_review(&ws_review)
    );
    assert_eq!(http_review["status"], "completed");
    assert_eq!(
        http_review["report"]["head_revision"],
        "0123456789abcdef0123456789abcdef01234567"
    );
    review_freshness::assert_live_head_advances_without_mutating_report(&client, &base_url).await;

    for status in [
        TaskBoardAiReviewReportStatus::Failed,
        TaskBoardAiReviewReportStatus::Cancelled,
    ] {
        db.append_task_board_ai_review_report(&terminal_report(
            "parity-http",
            status,
            "2026-07-29T18:00:01Z",
        ))
        .await
        .expect("append HTTP terminal report");
        db.append_task_board_ai_review_report(&terminal_report(
            "parity-ws",
            status,
            "2026-07-29T18:00:01Z",
        ))
        .await
        .expect("append WebSocket terminal report");
        let http_review = get_json(
            &client,
            &base_url,
            "/v1/task-board/items/parity-http/review-report",
        )
        .await;
        let ws_review = ws_result(
            &base_url,
            "req-task-board-review-report-terminal",
            ws_methods::TASK_BOARD_REVIEW_REPORT_GET,
            json!({ "id": "parity-ws" }),
        )
        .await;
        assert_eq!(
            normalized_review(&http_review),
            normalized_review(&ws_review)
        );
        assert_eq!(http_review["status"], status.as_str());
        assert_eq!(
            http_review["report"]["terminal_reason"],
            "provider stopped after partial output"
        );
    }

    let update_payload = json!({
        "status": "in_progress",
        "priority": "critical",
        "tags": ["parity", "updated"],
        "clear_planning": true,
        "clear_workflow": true,
    });
    let http_updated = put_json(
        &client,
        &base_url,
        "/v1/task-board/items/parity-http",
        update_payload.clone(),
    )
    .await;
    let mut ws_update_payload = update_payload;
    ws_update_payload["id"] = json!("parity-ws");
    let ws_updated = ws_result(
        &base_url,
        "req-task-board-update",
        ws_methods::TASK_BOARD_UPDATE,
        ws_update_payload,
    )
    .await;
    assert_eq!(normalized_item(&http_updated), normalized_item(&ws_updated));
    assert_eq!(http_updated["planning"], json!({}));
    assert!(http_updated.get("workflow").is_none());
    assert_eq!(ws_updated["planning"], json!({}));
    assert!(ws_updated.get("workflow").is_none());

    let http_deleted = delete_json(&client, &base_url, "/v1/task-board/items/parity-http").await;
    let ws_deleted = ws_result(
        &base_url,
        "req-task-board-delete",
        ws_methods::TASK_BOARD_DELETE,
        json!({ "id": "parity-ws" }),
    )
    .await;
    assert_eq!(normalized_item(&http_deleted), normalized_item(&ws_deleted));

    let (http_status, http_error) =
        get_json_status(&client, &base_url, "/v1/task-board/items/parity-missing").await;
    let ws_error = ws_rpc(
        &base_url,
        "req-task-board-missing",
        ws_methods::TASK_BOARD_GET,
        json!({ "id": "parity-missing" }),
    )
    .await;

    assert_eq!(http_status, StatusCode::BAD_REQUEST);
    assert_eq!(ws_error["error"]["status_code"].as_u64(), Some(400));
    assert_eq!(ws_error["error"]["code"], http_error["error"]["code"]);
    assert_eq!(ws_error["error"]["message"], http_error["error"]["message"]);
    assert_eq!(ws_error["error"]["data"], http_error);

    workflow_progress::assert_missing_error(&client, &base_url).await;

    let (http_status, http_error) = get_json_status(
        &client,
        &base_url,
        "/v1/task-board/items/parity-missing/review-report",
    )
    .await;
    let ws_error = ws_rpc(
        &base_url,
        "req-task-board-review-report-missing",
        ws_methods::TASK_BOARD_REVIEW_REPORT_GET,
        json!({ "id": "parity-missing" }),
    )
    .await;
    assert_eq!(http_status, StatusCode::BAD_REQUEST);
    assert_eq!(ws_error["error"]["status_code"].as_u64(), Some(400));
    assert_eq!(ws_error["error"]["code"], http_error["error"]["code"]);
    assert_eq!(ws_error["error"]["message"], http_error["error"]["message"]);

    let (http_status, http_error) = get_json_status(
        &client,
        &base_url,
        "/v1/task-board/items/bad..id/review-report",
    )
    .await;
    let ws_error = ws_rpc(
        &base_url,
        "req-task-board-review-report-malformed",
        ws_methods::TASK_BOARD_REVIEW_REPORT_GET,
        json!({ "id": "bad..id" }),
    )
    .await;
    assert_eq!(http_status, StatusCode::BAD_REQUEST);
    assert_eq!(ws_error["error"]["status_code"].as_u64(), Some(400));
    assert_eq!(ws_error["error"]["code"], http_error["error"]["code"]);
    assert_eq!(ws_error["error"]["message"], http_error["error"]["message"]);

    server.abort();
    let _ = server.await;
}

fn completed_report(item_id: &str) -> TaskBoardAiReviewReportRecord {
    TaskBoardAiReviewReportRecord {
        report_id: format!("report-{item_id}"),
        item_id: item_id.into(),
        correlation_id: format!("correlation-{item_id}"),
        repository: "smykla-skalski/harness".into(),
        pull_request_number: 1147,
        head_revision: "0123456789abcdef0123456789abcdef01234567".into(),
        runtime: "openrouter".into(),
        requested_runtime: "openrouter".into(),
        actual_runtime: Some("openrouter".into()),
        requested_model: "deepseek/deepseek-v4-flash".into(),
        effective_model: Some("deepseek/deepseek-v4-flash".into()),
        status: TaskBoardAiReviewReportStatus::Completed,
        summary: Some("No findings.".into()),
        findings: Vec::new(),
        partial_output: None,
        terminal_reason: None,
        started_at: "2026-07-29T18:00:00Z".into(),
        finished_at: "2026-07-29T18:00:01Z".into(),
    }
}

fn terminal_report(
    item_id: &str,
    status: TaskBoardAiReviewReportStatus,
    finished_at: &str,
) -> TaskBoardAiReviewReportRecord {
    let mut report = completed_report(item_id);
    report.report_id = format!("report-{item_id}-{}", status.as_str());
    report.correlation_id = format!("correlation-{item_id}-{}", status.as_str());
    report.status = status;
    report.summary = None;
    report.partial_output = Some("Partial structured review output.".into());
    report.terminal_reason = Some("provider stopped after partial output".into());
    report.finished_at = finished_at.into();
    report
}
