use serde_json::{Value, json};
use tempfile::tempdir;

use crate::daemon::http::RemoteRequestLimitConfig;
use crate::daemon::http::remote_limits::DEFAULT_REMOTE_HTTP_BODY_LIMIT_BYTES;
use crate::daemon::protocol::{http_paths, ws_methods};
use crate::daemon::remote_auth::REMOTE_CLIENT_ID_HEADER;

use super::remote_limits_support::{remote_state_with_viewer_config, remote_token};
use super::task_board_route_parity_support::*;

#[test]
fn task_board_http_and_ws_policy_io_routes_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_policy_io_parity());
    });
}

#[test]
fn policy_transfer_http_routes_dump_and_import_batches() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_policy_transfer_routes());
    });
}

#[test]
fn policy_transfer_http_routes_honor_larger_configured_remote_body_limits() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_policy_transfer_larger_remote_body());
    });
}

async fn run_policy_transfer_larger_remote_body() {
    let configured_limit = DEFAULT_REMOTE_HTTP_BODY_LIMIT_BYTES + 256 * 1024;
    let state = remote_state_with_viewer_config(RemoteRequestLimitConfig {
        max_http_body_bytes: configured_limit,
        ..RemoteRequestLimitConfig::default()
    });
    state
        .async_db
        .get()
        .expect("test async db")
        .replace_policy_workspace(
            &crate::task_board::policy_graph::PolicyCanvasWorkspace::seeded(),
        )
        .await
        .expect("seed policy workspace");
    let (base_url, server) = serve_http(state).await;
    let response = reqwest::Client::new()
        .post(format!("{base_url}{}", http_paths::POLICIES_DUMP))
        .header(REMOTE_CLIENT_ID_HEADER, "viewer")
        .bearer_auth(remote_token("viewer"))
        .json(&json!({
            "padding": "x".repeat(DEFAULT_REMOTE_HTTP_BODY_LIMIT_BYTES + 1),
        }))
        .send()
        .await
        .expect("send transfer request above the default body limit");

    let status = response.status();
    let body = response.text().await.expect("read transfer response");
    assert_eq!(status, reqwest::StatusCode::OK, "unexpected body: {body}");
    server.abort();
    let _ = server.await;
}

async fn run_policy_transfer_routes() {
    let state = super::test_http_state_with_db();
    let test_db = state.async_db.get().expect("test async db").clone();
    let mut workspace = crate::task_board::policy_graph::PolicyCanvasWorkspace::seeded();
    workspace.canvases[0].id = "policy,one".to_string();
    workspace.active_canvas_id = workspace.canvases[0].id.clone();
    test_db
        .replace_policy_workspace(&workspace)
        .await
        .expect("seed policy workspace");
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let dump = post_json(&client, &base_url, http_paths::POLICIES_DUMP, json!({})).await;
    assert_eq!(dump["format"], "harness-policy-transfer");
    assert_eq!(dump["version"], 1);
    let policy_count = dump["policies"]
        .as_array()
        .expect("dumped policy list")
        .len();
    assert!(
        policy_count > 1,
        "all-policy dump should contain seeded policies"
    );

    let selected = post_json(
        &client,
        &base_url,
        http_paths::POLICIES_DUMP,
        json!({ "policy_ids": ["policy,one"] }),
    )
    .await;
    assert_eq!(selected["policies"].as_array().map(Vec::len), Some(1));
    assert_eq!(selected["policies"][0]["id"], "policy,one");
    assert!(selected["workspace"].is_null());

    let padded_import = post_json(
        &client,
        &base_url,
        http_paths::POLICIES_IMPORT,
        json!({
            "bundle": selected,
            "replace_all": false,
            "padding": "x".repeat(2 * 1024 * 1024 + 64),
        }),
    )
    .await;
    assert!(
        padded_import["canvases"]
            .as_array()
            .is_some_and(|canvases| !canvases.is_empty())
    );

    let imported = post_json(
        &client,
        &base_url,
        http_paths::POLICIES_IMPORT,
        json!({ "bundle": dump, "replace_all": true }),
    )
    .await;
    assert_eq!(
        imported["canvases"]
            .as_array()
            .expect("imported policy summaries")
            .len(),
        policy_count,
    );

    server.abort();
    let _ = server.await;
}

async fn run_policy_io_parity() {
    let state = super::test_http_state_with_db();
    let test_db = state.async_db.get().expect("test async db").clone();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    reset_policy_workspace(&test_db).await;
    let http_canvas_id = active_policy_canvas_id(&client, &base_url).await;
    let http_export = post_json(
        &client,
        &base_url,
        http_paths::POLICY_CANVAS_EXPORT,
        json!({ "canvas_id": http_canvas_id }),
    )
    .await;

    reset_policy_workspace(&test_db).await;
    let ws_canvas_id = active_policy_canvas_id(&client, &base_url).await;
    let ws_export = ws_result(
        &base_url,
        "req-task-board-policy-export",
        ws_methods::POLICY_CANVAS_EXPORT,
        json!({ "canvas_id": ws_canvas_id }),
    )
    .await;
    assert_eq!(
        normalized_policy_export(&http_export),
        normalized_policy_export(&ws_export)
    );

    let import_payload = json!({
        "title": "Imported policy",
        "document": http_export["document"].clone(),
    });
    reset_policy_workspace(&test_db).await;
    let http_import = post_json(
        &client,
        &base_url,
        http_paths::POLICY_CANVAS_IMPORT,
        import_payload.clone(),
    )
    .await;
    reset_policy_workspace(&test_db).await;
    let ws_import = ws_result(
        &base_url,
        "req-task-board-policy-import",
        ws_methods::POLICY_CANVAS_IMPORT,
        import_payload,
    )
    .await;
    assert_eq!(
        normalized_imported_policy_canvas(&http_import),
        normalized_imported_policy_canvas(&ws_import)
    );

    server.abort();
    let _ = server.await;
}

fn normalized_policy_export(value: &Value) -> Value {
    let mut value = normalized_policy(value);
    value["canvas_id"] = json!("normalized-canvas");
    value
}

fn normalized_imported_policy_canvas(value: &Value) -> Value {
    let workspace = normalized_policy_workspace(value);
    let active_canvas_id = workspace["active_canvas_id"]
        .as_str()
        .expect("active imported canvas id");
    let mut canvas = workspace["canvases"]
        .as_array()
        .expect("policy canvases")
        .iter()
        .find(|canvas| canvas["id"].as_str() == Some(active_canvas_id))
        .expect("active imported canvas")
        .clone();
    canvas["id"] = json!("normalized-canvas");
    canvas["canvas_id"] = json!("normalized-canvas");
    json!({
        "active_canvas": canvas,
        "global_policy_enforcement_enabled": workspace["global_policy_enforcement_enabled"].clone(),
        "schema_version": workspace["schema_version"].clone(),
    })
}
