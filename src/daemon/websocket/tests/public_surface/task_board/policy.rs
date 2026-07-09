use serde_json::json;

use super::*;

#[test]
fn websocket_policy_make_live_and_go_live_diff_round_trip() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));
            let workspace_response = dispatch(
                &request(
                    "req-make-live-workspace",
                    ws_methods::POLICY_CANVAS_WORKSPACE_GET,
                    json!({}),
                ),
                &state,
                &connection,
            )
            .await;
            let active_canvas_id = response_result(&workspace_response)["active_canvas_id"]
                .as_str()
                .expect("active canvas id")
                .to_string();

            let get_response = dispatch(
                &request(
                    "req-make-live-get",
                    ws_methods::POLICY_PIPELINE_GET,
                    json!({ "canvas_id": active_canvas_id.clone() }),
                ),
                &state,
                &connection,
            )
            .await;
            let pipeline = response_result(&get_response);

            let save_response = dispatch(
                &request(
                    "req-make-live-save",
                    ws_methods::POLICY_PIPELINE_SAVE_DRAFT,
                    json!({
                        "canvas_id": active_canvas_id.clone(),
                        "document": pipeline.clone(),
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let saved = response_result(&save_response);
            let saved_revision = saved["document"]["revision"].as_u64().expect("revision");

            // Before going live, nothing is enforced, so the diff reports parity.
            let pre_diff_response = dispatch(
                &request(
                    "req-go-live-diff-pre",
                    ws_methods::POLICY_PIPELINE_GO_LIVE_DIFF,
                    json!({ "canvas_id": active_canvas_id.clone() }),
                ),
                &state,
                &connection,
            )
            .await;
            let pre_diff = response_result(&pre_diff_response);
            assert_eq!(pre_diff["has_live_policy"].as_bool(), Some(false));

            let make_live_response = dispatch(
                &request(
                    "req-make-live",
                    ws_methods::POLICY_PIPELINE_MAKE_LIVE,
                    json!({
                        "canvas_id": active_canvas_id.clone(),
                        "revision": saved_revision,
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let made_live = response_result(&make_live_response);
            assert_eq!(made_live["document"]["mode"].as_str(), Some("enforced"));
            assert_eq!(
                made_live["global_policy_enforcement_enabled"].as_bool(),
                Some(true)
            );
            assert!(
                made_live["workspace"]["scenarios"].is_array(),
                "make-live carries the workspace snapshot"
            );

            // The live policy diffed against itself stays at parity.
            let post_diff_response = dispatch(
                &request(
                    "req-go-live-diff-post",
                    ws_methods::POLICY_PIPELINE_GO_LIVE_DIFF,
                    json!({
                        "canvas_id": active_canvas_id,
                        "document": made_live["document"].clone(),
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let post_diff = response_result(&post_diff_response);
            assert_eq!(post_diff["has_live_policy"].as_bool(), Some(true));
            assert_eq!(post_diff["changed_count"].as_u64(), Some(0));
        });
    });
}

#[test]
fn websocket_policy_pipeline_replay_round_trip() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));
            // A fresh daemon has recorded no real decisions, so replay reports an
            // empty sample while still proving the full RPC surface is wired.
            let replay_response = dispatch(
                &request(
                    "req-replay",
                    ws_methods::POLICY_PIPELINE_REPLAY,
                    json!({ "limit": 25 }),
                ),
                &state,
                &connection,
            )
            .await;
            let replay = response_result(&replay_response);
            assert_eq!(replay["sample_size"].as_u64(), Some(0));
            assert_eq!(replay["changed_count"].as_u64(), Some(0));
            assert_eq!(
                replay["decisions"].as_array().map_or(0, Vec::len),
                0,
                "fresh daemon has no recorded decisions to replay"
            );
        });
    });
}

#[test]
fn websocket_policy_pipeline_routes_round_trip() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));
            let workspace_response = dispatch(
                &request(
                    "req-policy-workspace",
                    ws_methods::POLICY_CANVAS_WORKSPACE_GET,
                    json!({}),
                ),
                &state,
                &connection,
            )
            .await;
            let active_canvas_id = response_result(&workspace_response)["active_canvas_id"]
                .as_str()
                .expect("active canvas id")
                .to_string();

            let get_response = dispatch(
                &request(
                    "req-policy-get",
                    ws_methods::POLICY_PIPELINE_GET,
                    json!({ "canvas_id": active_canvas_id.clone() }),
                ),
                &state,
                &connection,
            )
            .await;
            let pipeline = response_result(&get_response);
            assert_eq!(pipeline["schema_version"].as_u64(), Some(2));

            let save_response = dispatch(
                &request(
                    "req-policy-save",
                    ws_methods::POLICY_PIPELINE_SAVE_DRAFT,
                    json!({
                        "canvas_id": active_canvas_id.clone(),
                        "document": pipeline.clone(),
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let save = response_result(&save_response);
            let saved_revision = save["document"]["revision"]
                .as_u64()
                .expect("saved revision");

            let simulation_response = dispatch(
                &request(
                    "req-policy-simulate",
                    ws_methods::POLICY_PIPELINE_SIMULATE,
                    json!({
                        "canvas_id": active_canvas_id.clone(),
                        "document": save["document"].clone(),
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let simulation = response_result(&simulation_response);
            assert_eq!(simulation["revision"].as_u64(), Some(saved_revision));
            assert_eq!(simulation["succeeded"].as_bool(), Some(true));

            let promote_response = dispatch(
                &request(
                    "req-policy-promote",
                    ws_methods::POLICY_PIPELINE_PROMOTE,
                    json!({
                        "canvas_id": active_canvas_id.clone(),
                        "revision": saved_revision,
                    }),
                ),
                &state,
                &connection,
            )
            .await;
            let promote = response_result(&promote_response);
            assert_eq!(promote["document"]["mode"].as_str(), Some("enforced"));

            let audit_response = dispatch(
                &request(
                    "req-policy-audit",
                    ws_methods::POLICY_PIPELINE_AUDIT,
                    json!({ "canvas_id": active_canvas_id }),
                ),
                &state,
                &connection,
            )
            .await;
            let audit = response_result(&audit_response);
            assert_eq!(audit["active_revision"].as_u64(), Some(saved_revision));
            assert_eq!(
                audit["latest_simulation"]["revision"].as_u64(),
                Some(saved_revision)
            );
        });
    });
}

#[test]
fn websocket_policy_optional_routes_accept_missing_params() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));

            let workspace_request: WsRequest = serde_json::from_value(json!({
                "id": "req-policy-workspace-defaults",
                "method": ws_methods::POLICY_CANVAS_WORKSPACE_GET,
            }))
            .expect("workspace request with default params");
            let workspace_response = dispatch(&workspace_request, &state, &connection).await;
            assert!(
                workspace_response.error.is_none(),
                "unexpected workspace error: {:?}",
                workspace_response.error
            );
            let active_canvas_id =
                workspace_response.result.expect("workspace result")["active_canvas_id"]
                    .as_str()
                    .expect("active canvas id")
                    .to_string();
            assert!(
                active_canvas_id.starts_with("policy-canvas-"),
                "expected a seeded default canvas id, got {active_canvas_id:?}"
            );

            let pipeline_request: WsRequest = serde_json::from_value(json!({
                "id": "req-policy-get-defaults",
                "method": ws_methods::POLICY_PIPELINE_GET,
            }))
            .expect("pipeline request with default params");
            let pipeline_response = dispatch(&pipeline_request, &state, &connection).await;
            assert!(
                pipeline_response.error.is_none(),
                "unexpected pipeline error: {:?}",
                pipeline_response.error
            );
            assert_eq!(
                pipeline_response.result.expect("pipeline result")["schema_version"].as_u64(),
                Some(2)
            );

            let audit_request: WsRequest = serde_json::from_value(json!({
                "id": "req-policy-audit-defaults",
                "method": ws_methods::POLICY_PIPELINE_AUDIT,
            }))
            .expect("audit request with default params");
            let audit_response = dispatch(&audit_request, &state, &connection).await;
            assert!(
                audit_response.error.is_none(),
                "unexpected audit error: {:?}",
                audit_response.error
            );
            assert_eq!(
                audit_response.result.expect("audit result")["active_revision"].as_u64(),
                Some(1)
            );
        });
    });
}

#[test]
fn websocket_policy_scenario_crud_roundtrips() {
    let sandbox = tempdir().expect("tempdir");
    with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(async {
            let state =
                test_websocket_state_with_empty_async_db(&sandbox.path().join("daemon.sqlite"))
                    .await;
            let connection = Arc::new(Mutex::new(ConnectionState::new()));

            let workspace_request: WsRequest = serde_json::from_value(json!({
                "id": "req-scenario-workspace",
                "method": ws_methods::POLICY_CANVAS_WORKSPACE_GET,
            }))
            .expect("workspace request");
            let seeded = dispatch(&workspace_request, &state, &connection).await;
            let seeded_count = seeded.result.expect("workspace result")["scenarios"]
                .as_array()
                .expect("scenarios array")
                .len();
            assert!(seeded_count > 0, "workspace get seeds default scenarios");

            let create_request: WsRequest = serde_json::from_value(json!({
                "id": "req-scenario-create",
                "method": ws_methods::POLICY_SCENARIO_CREATE,
                "params": { "name": "Risky merge", "input": { "action": "merge_pr" } },
            }))
            .expect("scenario create request");
            let created = dispatch(&create_request, &state, &connection).await;
            assert!(
                created.error.is_none(),
                "unexpected create error: {:?}",
                created.error
            );
            let created_scenarios = created.result.expect("create result")["scenarios"]
                .as_array()
                .expect("scenarios array")
                .clone();
            assert_eq!(created_scenarios.len(), seeded_count + 1);
            assert!(
                created_scenarios
                    .iter()
                    .any(|scenario| scenario["name"] == "Risky merge"),
                "the created scenario appears in the workspace"
            );

            let reset_request: WsRequest = serde_json::from_value(json!({
                "id": "req-scenario-reset",
                "method": ws_methods::POLICY_SCENARIO_RESET,
            }))
            .expect("scenario reset request");
            let reset = dispatch(&reset_request, &state, &connection).await;
            assert!(
                reset.error.is_none(),
                "unexpected reset error: {:?}",
                reset.error
            );
            assert_eq!(
                reset.result.expect("reset result")["scenarios"]
                    .as_array()
                    .expect("scenarios array")
                    .len(),
                seeded_count
            );
        });
    });
}
