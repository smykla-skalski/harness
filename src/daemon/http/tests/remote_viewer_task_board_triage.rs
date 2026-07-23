use serde_json::{Value, json};

use crate::daemon::db::TaskBoardTriageOverrideSetInput;
use crate::daemon::protocol::{http_paths, ws_methods};
use crate::task_board::{TaskBoardItem, TaskBoardStatus, TriageVerdict};

use super::remote_viewer_support::ws_rpc;
use super::remote_viewer_task_board::{VIEWER_ID, assert_remote_write_denied};

pub(super) const TRIAGE_ITEM_ID: &str = "remote-triage-item";
const TRIAGE_OVERRIDE_ACTOR: &str = "operator-secret-override-actor";
const TRIAGE_OVERRIDE_REASON: &str = "operator secret override reason";

pub(super) async fn seed_triage_item(state: &crate::daemon::http::DaemonHttpState) {
    let mut item = TaskBoardItem::new(
        TRIAGE_ITEM_ID.into(),
        "Triage item".into(),
        "Verify triage redaction.".into(),
        "2026-07-23T00:00:00Z".into(),
    );
    item.status = TaskBoardStatus::Backlog;
    item.tags = vec!["triage/needs-info".to_string()];
    let db = state.async_db.get().expect("async db");
    db.create_task_board_item_with_triage(item)
        .await
        .expect("seed triage item");
    let snapshot = db.task_board_items_snapshot(None).await.expect("snapshot");
    let revision = snapshot
        .items
        .iter()
        .find(|item| item.item.id == TRIAGE_ITEM_ID)
        .expect("triage item in snapshot")
        .item_revision;
    // A verdict distinct from the automatic decision (needs-info -> Undecided)
    // so `current`, `triage_override`, and `effective` are each independently
    // observable in the response instead of one accidentally masking another.
    db.set_task_board_triage_override(TaskBoardTriageOverrideSetInput {
        item_id: TRIAGE_ITEM_ID.into(),
        verdict: TriageVerdict::Todo,
        actor: TRIAGE_OVERRIDE_ACTOR.into(),
        reason: Some(TRIAGE_OVERRIDE_REASON.into()),
        expected_item_revision: revision,
        expected_items_change_seq: snapshot.items_change_seq,
    })
    .await
    .expect("seed triage override");
}

pub(super) fn assert_viewer_triage_current(response: &Value) {
    let Some(current) = response["current"].as_object() else {
        panic!("expected a current triage decision, got {response}");
    };
    assert_eq!(current["item_id"], TRIAGE_ITEM_ID);
    assert!(current.get("reason_detail").is_some_and(Value::is_null));
    assert!(
        current
            .get("evidence_fingerprint")
            .is_some_and(Value::is_null)
    );
    let Some(triage_override) = response["triage_override"].as_object() else {
        panic!("expected an active triage override, got {response}");
    };
    assert_eq!(triage_override["verdict"], "todo");
    assert!(triage_override["set_at"].as_str().is_some());
    assert_eq!(triage_override["actor"], "[redacted]");
    assert!(triage_override.get("reason").is_none_or(Value::is_null));
    assert_eq!(response["effective"]["verdict"], "todo");
    assert_eq!(response["effective"]["source"], "override");
    let serialized = serde_json::to_string(response).expect("serialize viewer triage current");
    assert!(!serialized.contains(TRIAGE_OVERRIDE_ACTOR));
    assert!(!serialized.contains(TRIAGE_OVERRIDE_REASON));
}

pub(super) fn assert_viewer_triage_history(response: &Value) {
    let decisions = response["decisions"].as_array().expect("decisions array");
    assert!(!decisions.is_empty());
    for decision in decisions {
        assert!(decision.get("reason_detail").is_some_and(Value::is_null));
        assert!(
            decision
                .get("evidence_fingerprint")
                .is_some_and(Value::is_null)
        );
    }
}

pub(super) fn assert_full_triage_current(response: &Value) {
    let current = response["current"]
        .as_object()
        .expect("expected a current triage decision");
    assert_eq!(current["reason_code"], "needs_info_label");
    assert_eq!(current["reason_detail"], "triage/needs-info");
    assert!(current["evidence_fingerprint"].as_str().is_some());
    let triage_override = response["triage_override"]
        .as_object()
        .expect("expected an active triage override");
    assert_eq!(triage_override["actor"], TRIAGE_OVERRIDE_ACTOR);
    assert_eq!(triage_override["reason"], TRIAGE_OVERRIDE_REASON);
    assert_eq!(response["effective"]["source"], "override");
}

pub(super) async fn assert_viewer_triage_override_mutations_are_denied(
    client: &reqwest::Client,
    base_url: &str,
) {
    let set_path = http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE.replace("{item_id}", TRIAGE_ITEM_ID);
    let clear_path =
        http_paths::TASK_BOARD_ITEM_TRIAGE_OVERRIDE_CLEAR.replace("{item_id}", TRIAGE_ITEM_ID);
    for (request, params) in [
        (
            client.put(format!("{base_url}{set_path}")),
            triage_override_set_params(),
        ),
        (
            client.post(format!("{base_url}{clear_path}")),
            triage_override_clear_params(),
        ),
    ] {
        let response = request
            .header(
                crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER,
                VIEWER_ID,
            )
            .bearer_auth("remote-token-secret-viewer-task-board")
            .json(&params)
            .send()
            .await
            .expect("send viewer triage override mutation");
        let status = response.status();
        let body = response
            .json::<Value>()
            .await
            .expect("viewer mutation body");
        assert_eq!(status, reqwest::StatusCode::FORBIDDEN);
        assert_eq!(body["error"]["code"], "REMOTE_AUTH");
    }
}

pub(super) async fn assert_ws_viewer_triage_override_mutations_are_denied(
    socket: &mut tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
) {
    let ws_set = ws_rpc(
        socket,
        "viewer-triage-override-set",
        ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_SET,
        with_triage_id(triage_override_set_params()),
    )
    .await;
    assert_remote_write_denied(&ws_set);
    let ws_clear = ws_rpc(
        socket,
        "viewer-triage-override-clear",
        ws_methods::TASK_BOARD_TRIAGE_OVERRIDE_CLEAR,
        with_triage_id(triage_override_clear_params()),
    )
    .await;
    assert_remote_write_denied(&ws_clear);
}

fn triage_override_set_params() -> Value {
    json!({
        "verdict": "undecided",
        "expected_item_revision": 1,
        "expected_items_change_seq": 1,
        "actor": "spoofed-viewer",
    })
}

fn triage_override_clear_params() -> Value {
    json!({
        "expected_item_revision": 1,
        "expected_items_change_seq": 1,
        "actor": "spoofed-viewer",
    })
}

fn with_triage_id(mut params: Value) -> Value {
    params["id"] = json!(TRIAGE_ITEM_ID);
    params
}
