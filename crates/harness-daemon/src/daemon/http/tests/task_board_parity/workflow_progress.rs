use super::{StatusCode, Value, get_json, get_json_status, json, ws_methods, ws_result, ws_rpc};

pub(super) async fn assert_not_started(client: &reqwest::Client, base_url: &str) {
    let http_progress = get_json(
        client,
        base_url,
        "/v1/task-board/items/parity-http/workflow-progress",
    )
    .await;
    let ws_progress = ws_result(
        base_url,
        "req-task-board-workflow-progress-not-started",
        ws_methods::TASK_BOARD_WORKFLOW_PROGRESS_GET,
        json!({ "id": "parity-ws" }),
    )
    .await;
    assert_eq!(http_progress, json!({}));
    assert_eq!(http_progress, ws_progress);
}

pub(super) async fn assert_running(client: &reqwest::Client, base_url: &str) {
    let http_progress = get_json(
        client,
        base_url,
        "/v1/task-board/items/parity-http/workflow-progress",
    )
    .await;
    let ws_progress = ws_result(
        base_url,
        "req-task-board-workflow-progress-running",
        ws_methods::TASK_BOARD_WORKFLOW_PROGRESS_GET,
        json!({ "id": "parity-ws" }),
    )
    .await;
    assert_eq!(normalized(&http_progress), normalized(&ws_progress),);
    assert_eq!(http_progress["progress"]["phase"], "review");
    assert_eq!(http_progress["progress"]["state"], "running");
    assert_eq!(
        http_progress["progress"]["exact_head_revision"],
        "0123456789abcdef0123456789abcdef01234567"
    );
}

pub(super) async fn assert_missing_error(client: &reqwest::Client, base_url: &str) {
    let (http_status, http_error) = get_json_status(
        client,
        base_url,
        "/v1/task-board/items/parity-missing/workflow-progress",
    )
    .await;
    let ws_error = ws_rpc(
        base_url,
        "req-task-board-workflow-progress-missing",
        ws_methods::TASK_BOARD_WORKFLOW_PROGRESS_GET,
        json!({ "id": "parity-missing" }),
    )
    .await;
    assert_eq!(http_status, StatusCode::BAD_REQUEST);
    assert_eq!(ws_error["error"]["status_code"].as_u64(), Some(400));
    assert_eq!(ws_error["error"]["code"], http_error["error"]["code"]);
    assert_eq!(ws_error["error"]["message"], http_error["error"]["message"]);
    assert_eq!(ws_error["error"]["data"], http_error);
}

fn normalized(value: &Value) -> Value {
    let mut value = value.clone();
    value["progress"]["execution_id"] = json!("execution-normalized");
    value
}
