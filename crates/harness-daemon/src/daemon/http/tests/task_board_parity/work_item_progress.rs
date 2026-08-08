use super::{StatusCode, Value, get_json, get_json_status, json, ws_methods, ws_result, ws_rpc};
use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::db::task_board::prelude::*;

pub(super) async fn assert_not_dispatched(client: &reqwest::Client, base_url: &str) {
    let http_progress = get_json(
        client,
        base_url,
        "/v1/task-board/items/parity-http/progress",
    )
    .await;
    let ws_progress = ws_result(
        base_url,
        "req-task-board-progress-not-dispatched",
        ws_methods::TASK_BOARD_PROGRESS_GET,
        json!({ "id": "parity-ws" }),
    )
    .await;
    assert_eq!(http_progress, json!({}));
    assert_eq!(http_progress, ws_progress);
}

pub(super) async fn link_work_items(db: &AsyncDaemonDb) {
    for (item_id, work_item_id) in [
        ("parity-http", "task-board-parity-http"),
        ("parity-ws", "task-board-parity-ws"),
    ] {
        db.update_task_board_item(item_id, |item| {
            item.work_item_id = Some(work_item_id.to_string());
            Ok(true)
        })
        .await
        .expect("link the parity work item");
    }
}

pub(super) async fn assert_report_and_read_agree(client: &reqwest::Client, base_url: &str) {
    let report = json!({
        "state": "running",
        "summary": "wrote the failing test",
        "progress_percent": 40
    });
    let http_report = super::post_json(
        client,
        base_url,
        "/v1/task-board/items/parity-http/progress/report",
        report.clone(),
    )
    .await;
    let mut ws_payload = report;
    ws_payload["id"] = json!("parity-ws");
    let ws_report = ws_result(
        base_url,
        "req-task-board-progress-report",
        ws_methods::TASK_BOARD_PROGRESS_REPORT,
        ws_payload,
    )
    .await;

    assert_eq!(normalized(&http_report), normalized(&ws_report));
    assert_eq!(http_report["applied"], json!(true));
    assert_eq!(http_report["progress"]["state"], "running");
    assert_eq!(http_report["progress"]["progress_percent"], json!(40));

    let http_progress = get_json(
        client,
        base_url,
        "/v1/task-board/items/parity-http/progress",
    )
    .await;
    assert_eq!(
        normalized(&http_progress)["progress"],
        normalized(&http_report)["progress"]
    );
}

pub(super) async fn assert_missing_error(client: &reqwest::Client, base_url: &str) {
    let (http_status, http_error) = get_json_status(
        client,
        base_url,
        "/v1/task-board/items/parity-missing/progress",
    )
    .await;
    let ws_error = ws_rpc(
        base_url,
        "req-task-board-progress-missing",
        ws_methods::TASK_BOARD_PROGRESS_GET,
        json!({ "id": "parity-missing" }),
    )
    .await;
    assert_eq!(http_status, StatusCode::BAD_REQUEST);
    assert_eq!(ws_error["error"]["status_code"].as_u64(), Some(400));
    assert_eq!(ws_error["error"]["code"], http_error["error"]["code"]);
    assert_eq!(ws_error["error"]["message"], http_error["error"]["message"]);
}

/// The two transports drive two different items, so identity, timestamps, and
/// the minted checkpoint id differ by construction. Everything else has to
/// match exactly.
fn normalized(value: &Value) -> Value {
    let mut value = value.clone();
    let Some(progress) = value.get_mut("progress") else {
        return value;
    };
    progress["board_item_id"] = json!("normalized-item");
    progress["work_item_id"] = json!("normalized-work-item");
    progress["created_at"] = json!("normalized-time");
    progress["updated_at"] = json!("normalized-time");
    if let Some(checkpoints) = progress
        .get_mut("checkpoints")
        .and_then(Value::as_array_mut)
    {
        for checkpoint in checkpoints {
            checkpoint["checkpoint_id"] = json!("normalized-checkpoint");
            checkpoint["recorded_at"] = json!("normalized-time");
        }
    }
    value
}
