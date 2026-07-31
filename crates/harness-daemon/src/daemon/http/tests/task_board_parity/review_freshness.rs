use serde_json::json;

use super::{get_json, normalized_item, put_json, ws_methods, ws_result};

pub(super) async fn assert_live_head_advances_without_mutating_report(
    client: &reqwest::Client,
    base_url: &str,
) {
    let advanced_head = "89abcdef0123456789abcdef0123456789abcdef";
    let workflow_update = json!({
        "workflow": {
            "status": "running",
            "branch": "feature/parity",
            "pr_head_revision": advanced_head
        }
    });
    let http_advanced = put_json(
        client,
        base_url,
        "/v1/task-board/items/parity-http",
        workflow_update.clone(),
    )
    .await;
    let mut ws_workflow_update = workflow_update;
    ws_workflow_update["id"] = json!("parity-ws");
    let ws_advanced = ws_result(
        base_url,
        "req-task-board-head-advance",
        ws_methods::TASK_BOARD_UPDATE,
        ws_workflow_update,
    )
    .await;
    assert_eq!(
        normalized_item(&http_advanced),
        normalized_item(&ws_advanced)
    );
    assert_eq!(http_advanced["workflow"]["pr_head_revision"], advanced_head);

    let old_head_report = get_json(
        client,
        base_url,
        "/v1/task-board/items/parity-http/review-report",
    )
    .await;
    assert_eq!(
        old_head_report["report"]["head_revision"],
        "0123456789abcdef0123456789abcdef01234567"
    );
}
