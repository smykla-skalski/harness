use serde_json::json;
use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::daemon::protocol::{http_paths, ws_methods};
use crate::task_board::policy_graph::PolicyCanvasWorkspace;

use super::task_board_route_parity_support::*;

#[test]
fn task_board_http_and_ws_workflow_routes_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_workflow_parity());
    });
}

async fn run_task_board_workflow_parity() {
    let state = super::test_http_state_with_db();
    let mut workspace = PolicyCanvasWorkspace::seeded();
    workspace.spawn_requires_live_policy = false;
    state
        .async_db
        .get()
        .expect("test async db")
        .replace_policy_workspace(&workspace)
        .await
        .expect("configure explicit parity fallback");
    seed_ready_board_item(&state, "parity-workflow", "Parity workflow item").await;
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();

    assert_planning_routes_match(&client, &base_url, &state).await;
    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_SYNC,
        ws_methods::TASK_BOARD_SYNC,
        json!({ "status": "todo", "direction": "push", "dry_run": true }),
    )
    .await;
    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_DISPATCH,
        ws_methods::TASK_BOARD_DISPATCH,
        json!({
            "id": "parity-workflow",
            "status": "todo",
            "dry_run": true,
            "actor": "spoofed-client",
        }),
    )
    .await;
    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_EVALUATE,
        ws_methods::TASK_BOARD_EVALUATE,
        json!({ "id": "parity-workflow", "status": "in_progress", "dry_run": true }),
    )
    .await;

    let http_audit = get_json(
        &client,
        &base_url,
        &format!("{}?status=todo", http_paths::TASK_BOARD_AUDIT),
    )
    .await;
    let ws_audit = ws_result(
        &base_url,
        "req-task-board-audit",
        ws_methods::TASK_BOARD_AUDIT,
        json!({ "status": "todo" }),
    )
    .await;
    assert_eq!(http_audit, ws_audit);

    server.abort();
    let _ = server.await;
}

async fn assert_planning_routes_match(
    client: &reqwest::Client,
    base_url: &str,
    state: &crate::daemon::http::DaemonHttpState,
) {
    seed_planning_board_item(state, "parity-plan-http").await;
    seed_planning_board_item(state, "parity-plan-ws").await;

    let http_begin = post_json(
        client,
        base_url,
        &planning_path(http_paths::TASK_BOARD_PLAN_BEGIN, "parity-plan-http"),
        json!({}),
    )
    .await;
    let ws_begin = ws_result(
        base_url,
        "req-task-board-plan-begin",
        ws_methods::TASK_BOARD_PLAN_BEGIN,
        json!({ "id": "parity-plan-ws" }),
    )
    .await;
    assert_eq!(
        normalized_planning_response(&http_begin),
        normalized_planning_response(&ws_begin)
    );

    let submit_body = json!({ "summary": "Use the semantic plan." });
    let http_submit = post_json(
        client,
        base_url,
        &planning_path(http_paths::TASK_BOARD_PLAN_SUBMIT, "parity-plan-http"),
        submit_body.clone(),
    )
    .await;
    let mut ws_submit_body = submit_body;
    ws_submit_body["id"] = json!("parity-plan-ws");
    let ws_submit = ws_result(
        base_url,
        "req-task-board-plan-submit",
        ws_methods::TASK_BOARD_PLAN_SUBMIT,
        ws_submit_body,
    )
    .await;
    assert_eq!(
        normalized_planning_response(&http_submit),
        normalized_planning_response(&ws_submit)
    );

    let approve_body = json!({
        "approved_by": "lead",
        "approved_at": "2026-05-14T02:00:00Z",
    });
    let http_approve = post_json(
        client,
        base_url,
        &planning_path(http_paths::TASK_BOARD_PLAN_APPROVE, "parity-plan-http"),
        approve_body.clone(),
    )
    .await;
    let mut ws_approve_body = approve_body;
    ws_approve_body["id"] = json!("parity-plan-ws");
    let ws_approve = ws_result(
        base_url,
        "req-task-board-plan-approve",
        ws_methods::TASK_BOARD_PLAN_APPROVE,
        ws_approve_body,
    )
    .await;
    assert_eq!(
        normalized_planning_response(&http_approve),
        normalized_planning_response(&ws_approve)
    );
}

#[test]
fn task_board_http_and_ws_orchestrator_routes_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_orchestrator_parity());
    });
}

async fn run_task_board_orchestrator_parity() {
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();

    let capabilities = get_json(&client, &base_url, http_paths::TASK_BOARD_CAPABILITIES).await;
    assert_eq!(capabilities["storage"], "database");
    assert!(capabilities["revision"].as_i64().is_some());
    assert!(
        capabilities["instance_id"]
            .as_str()
            .is_some_and(|value| value.starts_with("task-board-"))
    );
    assert_eq!(
        capabilities,
        ws_result(
            &base_url,
            "req-task-board-capabilities",
            ws_methods::TASK_BOARD_CAPABILITIES,
            json!({}),
        )
        .await
    );

    let http_status = get_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
    )
    .await;
    let ws_status = ws_result(
        &base_url,
        "req-task-board-orchestrator-status",
        ws_methods::TASK_BOARD_ORCHESTRATOR_STATUS,
        json!({}),
    )
    .await;
    assert_eq!(http_status, ws_status);

    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_START,
        ws_methods::TASK_BOARD_ORCHESTRATOR_START,
        json!({}),
    )
    .await;
    assert_run_once_routes_match(&client, &base_url, &state).await;
    assert_settings_routes_match(&client, &base_url).await;
    assert_runtime_config_routes_match(&client, &base_url).await;
    assert_http_ws_put_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS,
        ws_methods::TASK_BOARD_ORCHESTRATOR_GITHUB_TOKENS_SYNC,
        json!({
            "global_token": "global-token",
            "repository_tokens": [{ "repository": "owner/repo", "token": "repo-token" }],
        }),
    )
    .await;
    assert_http_ws_put_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN,
        ws_methods::TASK_BOARD_ORCHESTRATOR_TODOIST_TOKEN_SYNC,
        json!({ "token": "todoist-token" }),
    )
    .await;
    assert_http_ws_get_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
        ws_methods::TASK_BOARD_GIT_IDENTITY_DEFAULTS,
    )
    .await;
    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_GIT_SIGNING_VERIFY,
        ws_methods::TASK_BOARD_GIT_SIGNING_VERIFY,
        json!({}),
    )
    .await;
    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE,
        ws_methods::TASK_BOARD_GIT_RUNTIME_SECRET_HANDOFF_PREPARE,
        json!({}),
    )
    .await;
    assert_http_ws_post_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_STOP,
        ws_methods::TASK_BOARD_ORCHESTRATOR_STOP,
        json!({}),
    )
    .await;

    server.abort();
    let _ = server.await;
}

#[test]
fn task_board_http_and_ws_catalog_routes_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_catalog_parity());
    });
}

async fn run_task_board_catalog_parity() {
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    assert_http_ws_get_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_PROJECTS,
        ws_methods::TASK_BOARD_PROJECTS,
    )
    .await;
    assert_http_ws_get_match(
        &client,
        &base_url,
        http_paths::TASK_BOARD_MACHINES,
        ws_methods::TASK_BOARD_MACHINES,
    )
    .await;

    server.abort();
    let _ = server.await;
}

#[test]
fn task_board_http_and_ws_policy_pipeline_routes_match() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_policy_pipeline_parity());
    });
}

async fn run_policy_pipeline_parity() {
    let state = super::test_http_state_with_db();
    let test_db = state.async_db.get().expect("test async db").clone();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let workspace = get_json(&client, &base_url, http_paths::POLICY_CANVASES).await;
    let ws_workspace = ws_result(
        &base_url,
        "req-task-board-policy-canvas-workspace",
        ws_methods::POLICY_CANVAS_WORKSPACE_GET,
        json!({}),
    )
    .await;
    assert_eq!(workspace, ws_workspace);

    let active_canvas_id = workspace["active_canvas_id"]
        .as_str()
        .expect("active canvas id")
        .to_string();
    let pipeline = get_json(
        &client,
        &base_url,
        &format!(
            "{}?canvas_id={active_canvas_id}",
            http_paths::POLICY_PIPELINE
        ),
    )
    .await;
    let ws_pipeline = ws_result(
        &base_url,
        "req-task-board-policy-get",
        ws_methods::POLICY_PIPELINE_GET,
        json!({ "canvas_id": active_canvas_id.clone() }),
    )
    .await;
    assert_eq!(pipeline, ws_pipeline);

    let http_promote =
        save_simulate_and_promote_http(&client, &base_url, &pipeline, &active_canvas_id).await;
    let ws_promote = save_simulate_and_promote_ws(&base_url, &pipeline, &active_canvas_id).await;
    assert_eq!(
        normalized_policy(&http_promote),
        normalized_policy(&ws_promote)
    );

    let http_audit = get_json(
        &client,
        &base_url,
        &format!("{}?canvas_id={active_canvas_id}", http_paths::POLICY_AUDIT),
    )
    .await;
    let ws_audit = ws_result(
        &base_url,
        "req-task-board-policy-audit",
        ws_methods::POLICY_PIPELINE_AUDIT,
        json!({ "canvas_id": active_canvas_id }),
    )
    .await;
    assert_eq!(normalized_policy(&http_audit), normalized_policy(&ws_audit));

    assert_policy_canvas_routes_match(&client, &base_url, &test_db).await;

    server.abort();
    let _ = server.await;
}

async fn assert_policy_canvas_routes_match(
    client: &reqwest::Client,
    base_url: &str,
    db: &AsyncDaemonDb,
) {
    reset_policy_workspace(db).await;
    let http_create = post_json(
        client,
        base_url,
        http_paths::POLICY_CANVASES_CREATE,
        json!({ "title": "Secondary canvas" }),
    )
    .await;
    reset_policy_workspace(db).await;
    let ws_create = ws_result(
        base_url,
        "req-task-board-policy-canvas-create",
        ws_methods::POLICY_CANVAS_CREATE,
        json!({ "title": "Secondary canvas" }),
    )
    .await;
    assert_eq!(
        normalized_policy_workspace(&http_create),
        normalized_policy_workspace(&ws_create)
    );

    reset_policy_workspace(db).await;
    let http_canvas_id = active_policy_canvas_id(client, base_url).await;
    let http_duplicate = post_json(
        client,
        base_url,
        http_paths::POLICY_CANVASES_DUPLICATE,
        json!({
            "canvas_id": http_canvas_id,
            "title": "Copied canvas",
        }),
    )
    .await;
    reset_policy_workspace(db).await;
    let ws_canvas_id = active_policy_canvas_id(client, base_url).await;
    let ws_duplicate = ws_result(
        base_url,
        "req-task-board-policy-canvas-duplicate",
        ws_methods::POLICY_CANVAS_DUPLICATE,
        json!({
            "canvas_id": ws_canvas_id,
            "title": "Copied canvas",
        }),
    )
    .await;
    assert_eq!(
        normalized_policy_workspace(&http_duplicate),
        normalized_policy_workspace(&ws_duplicate)
    );

    reset_policy_workspace(db).await;
    let http_rename_canvas_id = active_policy_canvas_id(client, base_url).await;
    let http_rename = post_json(
        client,
        base_url,
        http_paths::POLICY_CANVASES_RENAME,
        json!({
            "canvas_id": http_rename_canvas_id,
            "title": "Renamed canvas",
        }),
    )
    .await;
    reset_policy_workspace(db).await;
    let ws_rename_canvas_id = active_policy_canvas_id(client, base_url).await;
    let ws_rename = ws_result(
        base_url,
        "req-task-board-policy-canvas-rename",
        ws_methods::POLICY_CANVAS_RENAME,
        json!({
            "canvas_id": ws_rename_canvas_id,
            "title": "Renamed canvas",
        }),
    )
    .await;
    assert_eq!(
        normalized_policy_workspace(&http_rename),
        normalized_policy_workspace(&ws_rename)
    );

    reset_policy_workspace(db).await;
    let (http_primary_canvas_id, _http_secondary_canvas_id) =
        seed_policy_canvas_pair(client, base_url).await;
    let http_set_active = post_json(
        client,
        base_url,
        http_paths::POLICY_CANVASES_ACTIVE,
        json!({ "canvas_id": http_primary_canvas_id }),
    )
    .await;
    reset_policy_workspace(db).await;
    let (ws_primary_canvas_id, _ws_secondary_canvas_id) =
        seed_policy_canvas_pair(client, base_url).await;
    let ws_set_active = ws_result(
        base_url,
        "req-task-board-policy-canvas-set-active",
        ws_methods::POLICY_CANVAS_SET_ACTIVE,
        json!({ "canvas_id": ws_primary_canvas_id }),
    )
    .await;
    assert_eq!(
        normalized_policy_workspace(&http_set_active),
        normalized_policy_workspace(&ws_set_active)
    );

    reset_policy_workspace(db).await;
    let (_http_primary_canvas_id, http_secondary_canvas_id) =
        seed_policy_canvas_pair(client, base_url).await;
    let http_delete = post_json(
        client,
        base_url,
        http_paths::POLICY_CANVASES_DELETE,
        json!({ "canvas_id": http_secondary_canvas_id }),
    )
    .await;
    reset_policy_workspace(db).await;
    let (_ws_primary_canvas_id, ws_secondary_canvas_id) =
        seed_policy_canvas_pair(client, base_url).await;
    let ws_delete = ws_result(
        base_url,
        "req-task-board-policy-canvas-delete",
        ws_methods::POLICY_CANVAS_DELETE,
        json!({ "canvas_id": ws_secondary_canvas_id }),
    )
    .await;
    assert_eq!(
        normalized_policy_workspace(&http_delete),
        normalized_policy_workspace(&ws_delete)
    );
}
