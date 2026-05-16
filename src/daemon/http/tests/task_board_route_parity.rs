use serde_json::json;
use tempfile::tempdir;

use crate::daemon::protocol::{http_paths, ws_methods};

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
    seed_ready_board_item("parity-workflow", "Parity workflow item");
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    assert_planning_routes_match(&client, &base_url).await;
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

async fn assert_planning_routes_match(client: &reqwest::Client, base_url: &str) {
    seed_planning_board_item("parity-plan-http");
    seed_planning_board_item("parity-plan-ws");

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
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

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
    assert_run_once_routes_match(&client, &base_url).await;
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
        runtime.block_on(run_task_board_policy_pipeline_parity());
    });
}

async fn run_task_board_policy_pipeline_parity() {
    let state = super::test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let pipeline = get_json(&client, &base_url, http_paths::TASK_BOARD_POLICY_PIPELINE).await;
    let ws_pipeline = ws_result(
        &base_url,
        "req-task-board-policy-get",
        ws_methods::TASK_BOARD_POLICY_PIPELINE_GET,
        json!({}),
    )
    .await;
    assert_eq!(pipeline, ws_pipeline);

    let http_promote = save_simulate_and_promote_http(&client, &base_url, &pipeline).await;
    let ws_promote = save_simulate_and_promote_ws(&base_url, &pipeline).await;
    assert_eq!(
        normalized_policy(&http_promote),
        normalized_policy(&ws_promote)
    );

    let http_audit = get_json(&client, &base_url, http_paths::TASK_BOARD_POLICY_AUDIT).await;
    let ws_audit = ws_result(
        &base_url,
        "req-task-board-policy-audit",
        ws_methods::TASK_BOARD_POLICY_PIPELINE_AUDIT,
        json!({}),
    )
    .await;
    assert_eq!(normalized_policy(&http_audit), normalized_policy(&ws_audit));

    server.abort();
    let _ = server.await;
}
