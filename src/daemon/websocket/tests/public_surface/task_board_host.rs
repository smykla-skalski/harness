use serde_json::{Value, json};

use super::super::*;

fn host_request(id: &str, method: &str, params: Value) -> WsRequest {
    WsRequest {
        id: id.to_string(),
        method: method.to_string(),
        params,
        trace_context: None,
    }
}

fn host_response_result(response: &WsResponse) -> Value {
    assert!(
        response.error.is_none(),
        "unexpected error: {:?}",
        response.error
    );
    response.result.clone().expect("websocket result")
}

#[test]
fn websocket_task_board_host_routes_round_trip_local_registry() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));

            let local_before = host_response_result(
                &dispatch(
                    &host_request("req-host-local-1", ws_methods::TASK_BOARD_HOST_LOCAL, json!({})),
                    &state,
                    &connection,
                )
                .await,
            );
            let local_id_before = required_string(&local_before, "id");
            assert!(
                is_empty_string_array_or_missing(&local_before["project_types"]),
                "fresh host should declare no project_types: {local_before:?}"
            );

            let set_response = host_response_result(
                &dispatch(
                    &host_request(
                        "req-host-set",
                        ws_methods::TASK_BOARD_HOST_SET_PROJECT_TYPES,
                        json!({ "project_types": ["web", "iOS"] }),
                    ),
                    &state,
                    &connection,
                )
                .await,
            );
            assert_eq!(required_string(&set_response, "id"), local_id_before);
            assert_string_array(
                &set_response["project_types"],
                &["web".to_string(), "iOS".to_string()],
            );

            let local_after = host_response_result(
                &dispatch(
                    &host_request("req-host-local-2", ws_methods::TASK_BOARD_HOST_LOCAL, json!({})),
                    &state,
                    &connection,
                )
                .await,
            );
            assert_string_array(
                &local_after["project_types"],
                &["web".to_string(), "iOS".to_string()],
            );

            let list_response = host_response_result(
                &dispatch(
                    &host_request("req-host-list", ws_methods::TASK_BOARD_HOST_LIST, json!({})),
                    &state,
                    &connection,
                )
                .await,
            );
            let entries = list_response.as_array().expect("host list is array");
            assert_eq!(entries.len(), 1, "expected single registered host");
            assert_eq!(required_string(&entries[0], "id"), local_id_before);

            let cleared = host_response_result(
                &dispatch(
                    &host_request(
                        "req-host-clear",
                        ws_methods::TASK_BOARD_HOST_SET_PROJECT_TYPES,
                        json!({ "project_types": [] }),
                    ),
                    &state,
                    &connection,
                )
                .await,
            );
            assert!(
                is_empty_string_array_or_missing(&cleared["project_types"]),
                "cleared host should report empty project_types: {cleared:?}"
            );
        });
    });
}

fn required_string(value: &Value, key: &str) -> String {
    value[key]
        .as_str()
        .unwrap_or_else(|| panic!("missing string field `{key}` in {value:?}"))
        .to_string()
}

fn is_empty_string_array_or_missing(value: &Value) -> bool {
    matches!(value, Value::Null) || value.as_array().is_some_and(Vec::is_empty)
}

fn assert_string_array(value: &Value, expected: &[String]) {
    let actual: Vec<String> = value
        .as_array()
        .unwrap_or_else(|| panic!("expected array, got {value:?}"))
        .iter()
        .map(|entry| {
            entry
                .as_str()
                .unwrap_or_else(|| panic!("non-string in array: {entry:?}"))
                .to_string()
        })
        .collect();
    assert_eq!(&actual, expected, "array mismatch");
}
