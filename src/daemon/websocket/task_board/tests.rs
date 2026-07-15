const TASK_BOARD_WS_METHOD_CATALOG: &[&str] = &[
    ws_methods::TASK_BOARD_CREATE,
    ws_methods::TASK_BOARD_LIST,
    ws_methods::TASK_BOARD_GET,
    ws_methods::TASK_BOARD_UPDATE,
    ws_methods::TASK_BOARD_DELETE,
    ws_methods::TASK_BOARD_PLAN_BEGIN,
    ws_methods::TASK_BOARD_PLAN_SUBMIT,
    ws_methods::TASK_BOARD_PLAN_APPROVE,
    ws_methods::TASK_BOARD_SYNC,
    ws_methods::TASK_BOARD_DISPATCH,
    ws_methods::TASK_BOARD_EVALUATE,
    ws_methods::TASK_BOARD_AUDIT,
    ws_methods::TASK_BOARD_PROJECTS,
    ws_methods::TASK_BOARD_MACHINES,
    ws_methods::TASK_BOARD_HOST_LOCAL,
    ws_methods::TASK_BOARD_HOST_LIST,
    ws_methods::TASK_BOARD_HOST_SET_PROJECT_TYPES,
    ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS,
    ws_methods::TASK_BOARD_ORCHESTRATOR_START,
    ws_methods::TASK_BOARD_ORCHESTRATOR_STOP,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
    ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET,
    ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET,
    ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE,
    ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC,
    ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC,
    ws_methods::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
    ws_methods::TASK_BOARD_GIT_SIGNING_VERIFY,
    ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE,
    ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_ACK,
    ws_methods::POLICY_PIPELINE_GET,
    ws_methods::POLICY_PIPELINE_SAVE_DRAFT,
    ws_methods::POLICY_PIPELINE_SIMULATE,
    ws_methods::POLICY_PIPELINE_PROMOTE,
    ws_methods::POLICY_PIPELINE_AUDIT,
];

use harness_testkit::with_isolated_harness_env;
use serde_json::json;
use tempfile::tempdir;

use super::super::test_support::test_http_state_with_db;
use super::*;

#[tokio::test]
async fn ws_task_board_method_parity_against_constants() {
    let state = test_http_state_with_db();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    for method in TASK_BOARD_WS_METHOD_CATALOG {
        let request = WsRequest {
            id: format!("ws-parity-{method}"),
            method: (*method).to_string(),
            params: json!({}),
            trace_context: None,
        };
        let response = dispatch_task_board_method(&request, &state, &connection).await;
        assert!(
            response.is_some(),
            "ws method {method} has no handler arm in dispatch_task_board_method",
        );
    }
}

#[tokio::test]
async fn ws_unknown_task_board_method_returns_none() {
    let state = test_http_state_with_db();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let request = WsRequest {
        id: "ws-parity-unknown".into(),
        method: "task_board.unknown_method".into(),
        params: json!({}),
        trace_context: None,
    };
    let response = dispatch_task_board_method(&request, &state, &connection).await;
    assert!(response.is_none());
}

#[tokio::test]
async fn ws_task_board_dispatch_pick_accepts_omitted_params() {
    let state = test_http_state_with_db();
    let connection = Arc::new(Mutex::new(ConnectionState::new()));
    let request: WsRequest = serde_json::from_value(json!({
        "id": "ws-dispatch-pick-default-params",
        "method": ws_methods::TASK_BOARD_DISPATCH_PICK,
    }))
    .expect("deserialize dispatch-pick request");
    assert!(request.params.is_null());

    let response = dispatch_task_board_method(&request, &state, &connection)
        .await
        .expect("dispatch-pick response");

    assert!(
        response.error.is_none(),
        "omitted dispatch-pick params returned an error: {:?}",
        response.error
    );
    assert_eq!(response.result, Some(json!({})));
}

#[test]
fn ws_task_board_sync_persists_exactly_one_audit_event() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(async {
                let state = test_http_state_with_db();
                let connection = Arc::new(Mutex::new(ConnectionState::new()));
                let response = dispatch_task_board_method(
                    &WsRequest {
                        id: "ws-sync-audit".into(),
                        method: ws_methods::TASK_BOARD_SYNC.into(),
                        params: json!({ "direction": "push", "dry_run": true }),
                        trace_context: None,
                    },
                    &state,
                    &connection,
                )
                .await;
                assert!(response.is_some());

                let events = state
                    .async_db
                    .get()
                    .expect("async db")
                    .load_audit_events(&crate::daemon::protocol::HarnessMonitorAuditEventsRequest {
                        action_keys: vec!["task_board.sync".into()],
                        ..Default::default()
                    })
                    .await
                    .expect("load audit events")
                    .events;
                assert_eq!(events.len(), 1);
                assert_eq!(events[0].outcome, "success");
                assert_eq!(
                    events[0].payload_json.as_ref().and_then(|payload| {
                        payload.get("trigger").and_then(serde_json::Value::as_str)
                    }),
                    Some("requested")
                );
            });
    });
}
