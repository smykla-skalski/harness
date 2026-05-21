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
    ws_methods::TASK_BOARD_GIT_RUNTIME_DRAIN_SECRETS,
    ws_methods::TASK_BOARD_POLICY_PIPELINE_GET,
    ws_methods::TASK_BOARD_POLICY_PIPELINE_SAVE_DRAFT,
    ws_methods::TASK_BOARD_POLICY_PIPELINE_SIMULATE,
    ws_methods::TASK_BOARD_POLICY_PIPELINE_PROMOTE,
    ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT,
];

use serde_json::json;

use super::super::test_support::test_http_state_with_db;
use super::*;

#[tokio::test]
async fn ws_task_board_method_parity_against_constants() {
    let state = test_http_state_with_db();
    for method in TASK_BOARD_WS_METHOD_CATALOG {
        let request = WsRequest {
            id: format!("ws-parity-{method}"),
            method: (*method).to_string(),
            params: json!({}),
            trace_context: None,
        };
        let response = dispatch_task_board_method(&request, &state).await;
        assert!(
            response.is_some(),
            "ws method {method} has no handler arm in dispatch_task_board_method",
        );
    }
}

#[tokio::test]
async fn ws_unknown_task_board_method_returns_none() {
    let state = test_http_state_with_db();
    let request = WsRequest {
        id: "ws-parity-unknown".into(),
        method: "task_board.unknown_method".into(),
        params: json!({}),
        trace_context: None,
    };
    let response = dispatch_task_board_method(&request, &state).await;
    assert!(response.is_none());
}
