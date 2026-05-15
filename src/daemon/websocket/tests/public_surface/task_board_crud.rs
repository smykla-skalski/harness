use serde_json::{Value, json};

use crate::task_board::{TaskBoardStore, default_board_root};

use super::super::*;

#[test]
fn websocket_task_board_crud_sync_audit_and_orchestrator_routes_use_real_state() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));

            let created = call(
                &state,
                &connection,
                "req-crud-create",
                ws_methods::TASK_BOARD_CREATE,
                json!({
                    "id": "board-ws-crud",
                    "title": "WS CRUD item",
                    "body": "Create through websocket route",
                }),
            )
            .await;
            assert_eq!(created["id"].as_str(), Some("board-ws-crud"));
            let plan_begun = call(
                &state,
                &connection,
                "req-crud-plan-begin",
                ws_methods::TASK_BOARD_PLAN_BEGIN,
                json!({ "id": "board-ws-crud" }),
            )
            .await;
            assert_eq!(
                plan_begun["transition"]["to_status"].as_str(),
                Some("planning")
            );
            assert_eq!(plan_begun["item"]["status"].as_str(), Some("planning"));

            let plan_submitted = call(
                &state,
                &connection,
                "req-crud-plan-submit",
                ws_methods::TASK_BOARD_PLAN_SUBMIT,
                json!({
                    "id": "board-ws-crud",
                    "summary": "Use websocket planning coverage.",
                }),
            )
            .await;
            assert_eq!(
                plan_submitted["transition"]["to_status"].as_str(),
                Some("plan_review")
            );
            assert_eq!(
                plan_submitted["item"]["planning"]["summary"].as_str(),
                Some("Use websocket planning coverage.")
            );

            let plan_approved = call(
                &state,
                &connection,
                "req-crud-plan-approve",
                ws_methods::TASK_BOARD_PLAN_APPROVE,
                json!({
                    "id": "board-ws-crud",
                    "approved_by": "lead",
                    "approved_at": "2026-05-14T02:00:00Z",
                }),
            )
            .await;
            assert_eq!(
                plan_approved["transition"]["to_status"].as_str(),
                Some("todo")
            );
            assert_eq!(
                plan_approved["item"]["planning"]["approved_by"].as_str(),
                Some("lead")
            );

            let updated = call(
                &state,
                &connection,
                "req-crud-update",
                ws_methods::TASK_BOARD_UPDATE,
                json!({ "id": "board-ws-crud", "status": "todo", "priority": "high" }),
            )
            .await;
            assert_eq!(updated["status"].as_str(), Some("todo"));
            assert_eq!(
                call(
                    &state,
                    &connection,
                    "req-crud-get",
                    ws_methods::TASK_BOARD_GET,
                    json!({ "id": "board-ws-crud" }),
                )
                .await["priority"]
                    .as_str(),
                Some("high")
            );
            let listed = call(
                &state,
                &connection,
                "req-crud-list",
                ws_methods::TASK_BOARD_LIST,
                json!({ "status": "todo" }),
            )
            .await;
            assert_eq!(listed["items"].as_array().map(Vec::len), Some(1));
            let listed_without_params = call(
                &state,
                &connection,
                "req-crud-list-defaults",
                ws_methods::TASK_BOARD_LIST,
                Value::Null,
            )
            .await;
            assert_eq!(
                listed_without_params["items"].as_array().map(Vec::len),
                Some(1)
            );

            let sync = call(
                &state,
                &connection,
                "req-crud-sync",
                ws_methods::TASK_BOARD_SYNC,
                json!({
                    "status": "todo",
                    "direction": "push",
                    "dry_run": true,
                }),
            )
            .await;
            assert_eq!(sync["total"].as_u64(), Some(1));
            let sync_error = dispatch(
                &WsRequest {
                    id: "req-crud-sync-error".to_string(),
                    method: ws_methods::TASK_BOARD_SYNC.to_string(),
                    params: json!({
                        "provider": "todoist",
                        "direction": "pull",
                        "dry_run": true,
                    }),
                    trace_context: None,
                },
                &state,
                &connection,
            )
            .await;
            assert!(
                sync_error
                    .error
                    .as_ref()
                    .is_some_and(|error| error.message.contains("external sync token missing"))
            );
            let audit = call(
                &state,
                &connection,
                "req-crud-audit",
                ws_methods::TASK_BOARD_AUDIT,
                json!({ "status": "todo" }),
            )
            .await;
            assert_eq!(audit["total"].as_u64(), Some(1));
            let audit_request: WsRequest = serde_json::from_value(json!({
                "id": "req-crud-audit-defaults",
                "method": ws_methods::TASK_BOARD_AUDIT
            }))
            .expect("request with default params");
            let audit_without_params = dispatch(&audit_request, &state, &connection).await;
            assert!(
                audit_without_params.error.is_none(),
                "unexpected error: {:?}",
                audit_without_params.error
            );
            assert_eq!(
                audit_without_params.result.expect("websocket result")["total"].as_u64(),
                Some(1)
            );

            assert_eq!(
                call(
                    &state,
                    &connection,
                    "req-orch-status",
                    ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS,
                    json!({}),
                )
                .await["running"]
                    .as_bool(),
                Some(false)
            );
            assert_eq!(
                call(
                    &state,
                    &connection,
                    "req-orch-start",
                    ws_methods::TASK_BOARD_ORCHESTRATOR_START,
                    json!({}),
                )
                .await["running"]
                    .as_bool(),
                Some(true)
            );
            let settings = call(
                &state,
                &connection,
                "req-orch-settings",
                ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_UPDATE,
                json!({ "dry_run_default": false, "dispatch_status_filter": "todo" }),
            )
            .await;
            assert_eq!(settings["dry_run_default"].as_bool(), Some(false));
            let loaded_settings = call(
                &state,
                &connection,
                "req-orch-settings-get",
                ws_methods::TASK_BOARD_ORCHESTRATOR_SETTINGS_GET,
                json!({}),
            )
            .await;
            assert_eq!(loaded_settings["dry_run_default"].as_bool(), Some(false));
            let runtime_config = call(
                &state,
                &connection,
                "req-orch-runtime-config",
                ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_UPDATE,
                json!({
                    "global": {
                        "author_name": "Harness Bot",
                        "author_email": "bot@example.com",
                        "ssh_key_path": "/tmp/id_ed25519"
                    },
                    "repository_overrides": [
                        {
                            "repository": "owner/repo",
                            "profile": {
                                "author_email": "repo@example.com"
                            }
                        }
                    ]
                }),
            )
            .await;
            assert_eq!(
                runtime_config["global"]["author_name"].as_str(),
                Some("Harness Bot")
            );
            let loaded_runtime_config = call(
                &state,
                &connection,
                "req-orch-runtime-config-get",
                ws_methods::TASK_BOARD_ORCHESTRATOR_RUNTIME_CONFIG_GET,
                json!({}),
            )
            .await;
            assert_eq!(
                loaded_runtime_config["repository_overrides"][0]["repository"].as_str(),
                Some("owner/repo")
            );
            let tokens = call(
                &state,
                &connection,
                "req-orch-github-tokens",
                ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC,
                json!({
                    "global_token": "global-token",
                    "repository_tokens": [
                        {
                            "repository": "owner/repo",
                            "token": "repo-token"
                        }
                    ]
                }),
            )
            .await;
            assert_eq!(tokens["global_token_configured"].as_bool(), Some(true));
            assert_eq!(tokens["repository_token_count"].as_u64(), Some(1));
            let todoist = call(
                &state,
                &connection,
                "req-orch-todoist-token",
                ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC,
                json!({
                    "token": "todoist-token",
                }),
            )
            .await;
            assert_eq!(todoist["token_configured"].as_bool(), Some(true));
            assert_eq!(
                call(
                    &state,
                    &connection,
                    "req-orch-stop",
                    ws_methods::TASK_BOARD_ORCHESTRATOR_STOP,
                    json!({}),
                )
                .await["running"]
                    .as_bool(),
                Some(false)
            );

            let deleted = call(
                &state,
                &connection,
                "req-crud-delete",
                ws_methods::TASK_BOARD_DELETE,
                json!({ "id": "board-ws-crud" }),
            )
            .await;
            assert!(deleted["deleted_at"].as_str().is_some());
            assert!(
                TaskBoardStore::new(default_board_root())
                    .get("board-ws-crud")
                    .is_ok()
            );
        });
    });
}

async fn call(
    state: &crate::daemon::http::DaemonHttpState,
    connection: &Arc<Mutex<ConnectionState>>,
    id: &str,
    method: &str,
    params: Value,
) -> Value {
    let response = dispatch(
        &WsRequest {
            id: id.to_string(),
            method: method.to_string(),
            params,
            trace_context: None,
        },
        state,
        connection,
    )
    .await;
    assert!(
        response.error.is_none(),
        "unexpected error: {:?}",
        response.error
    );
    response.result.expect("websocket result")
}
