use serde_json::{Value, json};
use tempfile::tempdir;

use crate::daemon::db::NewApprovalGrant;
use crate::daemon::protocol::{http_paths, ws_methods};
use crate::task_board::{PolicyAction, PolicyReasonCode};

use super::task_board_route_parity_support::{post_json, serve_http, ws_result};

#[test]
fn policy_approval_grant_revoke_http_and_ws_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_revoke_route_parity());
    });
}

async fn run_revoke_route_parity() {
    let state = super::test_http_state_with_db();
    let db = state.async_db.get().expect("test async db").clone();
    let first = db
        .ensure_pending_approval_grant(&grant_fixture())
        .await
        .expect("seed HTTP grant");
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();
    let request = json!({ "grant_id": first.id, "actor": "operator" });

    let http = post_json(
        &client,
        &base_url,
        http_paths::POLICY_APPROVAL_GRANT_REVOKE,
        request,
    )
    .await;
    let second = db
        .ensure_pending_approval_grant(&grant_fixture())
        .await
        .expect("seed WebSocket grant");
    let ws = ws_result(
        &base_url,
        "req-policy-approval-grant-revoke",
        ws_methods::POLICY_APPROVAL_GRANT_REVOKE,
        json!({ "grant_id": second.id, "actor": "operator" }),
    )
    .await;

    assert_eq!(http["grant"]["state"], "revoked");
    assert_eq!(ws["grant"]["state"], "revoked");
    assert_eq!(
        normalized_revoke_response(http),
        normalized_revoke_response(ws)
    );
    server.abort();
    let _ = server.await;
}

fn grant_fixture() -> NewApprovalGrant {
    NewApprovalGrant {
        board_item_id: "policy-grant-route-parity".into(),
        action: PolicyAction::SpawnAgent,
        canvas_id: Some("policy-canvas-route-parity".into()),
        canvas_revision: 7,
        node_id: "approval-gate-route-parity".into(),
        reason_code: PolicyReasonCode::ApprovalRequired,
        expiry_seconds: Some(3_600),
    }
}

fn normalized_revoke_response(mut response: Value) -> Value {
    let grant = response["grant"].as_object_mut().expect("grant response");
    for key in ["id", "created_at", "resolved_at", "updated_at"] {
        grant.remove(key);
    }
    response
}
