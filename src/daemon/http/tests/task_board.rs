use std::path::Path;

use serde_json::json;
use tempfile::tempdir;

use crate::daemon::protocol::http_paths;
use crate::task_board::policy_graph::PolicyCanvasWorkspace;
use crate::task_board::{AgentMode, TaskBoardStatus};

use super::task_board_managed_worker_assertions::assert_codex_worker_started;
use super::task_board_support::*;
use super::*;

#[test]
fn task_board_http_dispatch_evaluate_and_run_once_use_real_state() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_http_flow(sandbox.path()));
    });
}

#[test]
fn task_board_http_step_mode_holds_worker_until_delivery() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_step_mode_hold(sandbox.path()));
    });
}

#[test]
fn task_board_http_pick_previews_highest_priority_item() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_pick_preview());
    });
}

#[test]
fn task_board_http_policy_pipeline_routes_round_trip() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_http_policy_pipeline_flow());
    });
}

#[test]
fn task_board_http_catalog_routes_use_real_state() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_http_catalog_flow());
    });
}

#[test]
fn task_board_http_plan_revoke_round_trips() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        runtime.block_on(run_task_board_http_plan_revoke_flow());
    });
}

async fn run_task_board_http_flow(sandbox: &Path) {
    let project_dir = sandbox.join("project");
    harness_testkit::init_git_repo_with_seed(&project_dir);
    let state = test_http_state_with_db();
    allow_fallback_spawn_for_test(&state).await;
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();

    run_task_board_http_item_scope_flow(&client, &base_url, &state, &project_dir).await;
    run_task_board_http_run_once_flow(&client, &base_url, &state, &project_dir).await;

    server.abort();
    let _ = server.await;
}

async fn run_task_board_step_mode_hold(sandbox: &Path) {
    let project_dir = sandbox.join("step-project");
    harness_testkit::init_git_repo_with_seed(&project_dir);
    let state = test_http_state_with_db();
    allow_fallback_spawn_for_test(&state).await;
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();
    put_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_SETTINGS,
        json!({ "step_mode": true }),
    )
    .await;
    seed_ready_board_item(&state, "board-step-held", "Held step item").await;

    let response = dispatch_http_item(&client, &base_url, "board-step-held", &project_dir).await;
    let applied = first_applied(&response);
    let session_id = required_string(applied, "session_id");

    assert_eq!(
        applied["item"]["workflow"]["current_step_id"].as_str(),
        Some("awaiting_delivery")
    );
    assert!(
        state
            .codex_controller
            .list_runs(&session_id)
            .expect("list held runs")
            .runs
            .is_empty()
    );
    let status = get_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
    )
    .await;
    assert_eq!(status["held_dispatches"]["count"].as_u64(), Some(1));
    assert_eq!(
        status["held_dispatches"]["items"][0]["board_item_id"].as_str(),
        Some("board-step-held")
    );
    let preview = post_json(
        &client,
        &base_url,
        "/v1/task-board/dispatch/deliver",
        json!({ "item_id": "board-step-held", "dry_run": true }),
    )
    .await;
    assert_eq!(preview["started_agent"], serde_json::Value::Null);
    assert!(
        preview["rendered_prompt"]
            .as_str()
            .is_some_and(|prompt| { prompt.contains("Board item: board-step-held") })
    );
    let delivered = post_json(
        &client,
        &base_url,
        "/v1/task-board/dispatch/deliver",
        json!({ "item_id": "board-step-held" }),
    )
    .await;
    assert!(delivered["started_agent"].is_object());
    assert_eq!(
        delivered["applied"]["item"]["workflow"]["current_step_id"].as_str(),
        Some("worker_running")
    );
    assert_codex_worker_started(
        &state,
        &session_id,
        "board-step-held",
        &required_string(applied, "work_item_id"),
    );

    seed_ready_board_item(&state, "board-step-broad-high", "Broad high item").await;
    seed_ready_board_item(&state, "board-step-broad-low", "Broad low item").await;
    put_json(
        &client,
        &base_url,
        "/v1/task-board/items/board-step-broad-high",
        json!({ "priority": "critical" }),
    )
    .await;
    let broad = post_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
        json!({
            "status": "todo",
            "dry_run": false,
            "project_dir": project_dir,
        }),
    )
    .await;
    assert_eq!(
        broad["last_run"]["dispatch"]["applied"]
            .as_array()
            .map(Vec::len),
        Some(1),
        "step-mode Run Once must hold only one ready item"
    );
    assert_eq!(
        broad["held_dispatches"]["count"].as_u64(),
        Some(1),
        "only the newly selected item remains held"
    );
    assert_board_item_unlinked(&state, "board-step-broad-low").await;

    server.abort();
    let _ = server.await;
}

async fn run_task_board_pick_preview() {
    let state = test_http_state_with_db();
    allow_fallback_spawn_for_test(&state).await;
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();
    seed_ready_board_item(&state, "board-pick-low", "Low item").await;
    seed_ready_board_item(&state, "board-pick-high", "High item").await;
    put_json(
        &client,
        &base_url,
        "/v1/task-board/items/board-pick-high",
        json!({ "priority": "critical" }),
    )
    .await;

    let picked = post_json(
        &client,
        &base_url,
        "/v1/task-board/dispatch/pick",
        json!({}),
    )
    .await;
    assert_eq!(
        picked["selection"]["item"]["id"].as_str(),
        Some("board-pick-high")
    );
    assert_eq!(
        picked["selection"]["plan"]["board_item_id"].as_str(),
        Some("board-pick-high")
    );
    assert!(
        picked["selection"]["plan"]["rendered_prompt"]
            .as_str()
            .is_some_and(|prompt| prompt.contains("Board item: board-pick-high"))
    );

    server.abort();
    let _ = server.await;
}

async fn allow_fallback_spawn_for_test(state: &crate::daemon::http::DaemonHttpState) {
    let mut workspace = PolicyCanvasWorkspace::seeded();
    workspace.spawn_requires_live_policy = false;
    state
        .async_db
        .get()
        .expect("test async db")
        .replace_policy_workspace(&workspace)
        .await
        .expect("configure explicit test fallback");
}

async fn run_task_board_http_item_scope_flow(
    client: &reqwest::Client,
    base_url: &str,
    state: &crate::daemon::http::DaemonHttpState,
    project_dir: &Path,
) {
    seed_ready_board_item(state, "board-http-dispatch", "HTTP dispatch item").await;
    seed_ready_board_item(
        state,
        "board-http-dispatch-other",
        "HTTP dispatch other item",
    )
    .await;
    let dispatch = dispatch_http_item(client, base_url, "board-http-dispatch", project_dir).await;
    let applied = first_applied(&dispatch);
    let session_id = required_string(applied, "session_id");
    let work_item_id = required_string(applied, "work_item_id");
    assert_eq!(
        applied["board_item_id"].as_str(),
        Some("board-http-dispatch")
    );
    assert_eq!(applied["item"]["status"].as_str(), Some("in_progress"));
    assert_eq!(
        applied["item"]["workflow"]["status"].as_str(),
        Some("running")
    );
    let managed_run_id =
        assert_codex_worker_started(state, &session_id, "board-http-dispatch", &work_item_id);
    assert_board_item_unlinked(state, "board-http-dispatch-other").await;
    let other_dispatch =
        dispatch_http_item(client, base_url, "board-http-dispatch-other", project_dir).await;
    let _ = first_applied(&other_dispatch);
    post_json(
        client,
        base_url,
        &format!("/v1/managed-agents/{managed_run_id}/stop"),
        json!({}),
    )
    .await;
    assert_board_item_status(state, "board-http-dispatch", TaskBoardStatus::Failed).await;
    let evaluation = post_json(
        client,
        base_url,
        http_paths::TASK_BOARD_EVALUATE,
        json!({
            "id": "board-http-dispatch",
            "status": "in_progress",
            "dry_run": false,
        }),
    )
    .await;
    assert_eq!(evaluation["updated"].as_u64(), Some(0));
    assert_eq!(evaluation["blocked"].as_u64(), Some(1));
    assert_eq!(
        evaluation["records"][0]["workflow_status"].as_str(),
        Some("failed")
    );
    assert_eq!(
        evaluation["records"][0]["board_item_id"].as_str(),
        Some("board-http-dispatch")
    );
    assert_board_item_status(
        state,
        "board-http-dispatch-other",
        TaskBoardStatus::InProgress,
    )
    .await;
}

async fn run_task_board_http_run_once_flow(
    client: &reqwest::Client,
    base_url: &str,
    state: &crate::daemon::http::DaemonHttpState,
    project_dir: &Path,
) {
    seed_ready_board_item(state, "board-http-run-once", "HTTP run once item").await;
    seed_ready_board_item(
        state,
        "board-http-run-once-other",
        "HTTP run once other item",
    )
    .await;
    let run_once = post_json(
        client,
        base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_RUN_ONCE,
        json!({
            "id": "board-http-run-once",
            "status": "todo",
            "dry_run": false,
            "project_dir": project_dir,
        }),
    )
    .await;
    assert_eq!(run_once["last_run"]["status"].as_str(), Some("completed"));
    assert_eq!(
        run_once["last_run"]["dispatch"]["applied"]
            .as_array()
            .map(Vec::len),
        Some(1)
    );
    assert_eq!(
        run_once["last_run"]["dispatch"]["applied"][0]["board_item_id"].as_str(),
        Some("board-http-run-once")
    );
    assert!(
        run_once["last_run"]["evaluation"]["evaluated"]
            .as_u64()
            .is_some_and(|count| count >= 1)
    );
    assert!(evaluation_records_contain(&run_once, "board-http-run-once"));
    assert!(
        run_once["last_run"]["policy_trace_ids"]
            .as_array()
            .is_some_and(|trace_ids| !trace_ids.is_empty())
    );
    let applied = &run_once["last_run"]["dispatch"]["applied"][0];
    let _managed_run_id = assert_codex_worker_started(
        state,
        &required_string(applied, "session_id"),
        "board-http-run-once",
        &required_string(applied, "work_item_id"),
    );
    assert_board_item_unlinked(state, "board-http-run-once-other").await;
}

async fn run_task_board_http_policy_pipeline_flow() {
    let state = test_http_state_with_db();
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();

    let workspace = get_json(&client, &base_url, http_paths::POLICY_CANVASES).await;
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
    assert_eq!(pipeline["schema_version"].as_u64(), Some(2));
    assert_eq!(pipeline["mode"].as_str(), Some("draft"));

    let save = put_json(
        &client,
        &base_url,
        http_paths::POLICY_PIPELINE,
        json!({
            "canvas_id": active_canvas_id.clone(),
            "document": pipeline,
        }),
    )
    .await;
    assert!(
        save["validation"]["issues"]
            .as_array()
            .is_none_or(Vec::is_empty)
    );
    let saved_revision = save["document"]["revision"]
        .as_u64()
        .expect("saved revision");

    let simulation = post_json(
        &client,
        &base_url,
        http_paths::POLICY_SIMULATE,
        json!({
            "canvas_id": active_canvas_id.clone(),
            "document": save["document"].clone(),
        }),
    )
    .await;
    assert_eq!(simulation["revision"].as_u64(), Some(saved_revision));
    assert_eq!(simulation["succeeded"].as_bool(), Some(true));
    assert!(
        simulation["trace_id"]
            .as_str()
            .is_some_and(|id| !id.is_empty())
    );

    let promote = post_json(
        &client,
        &base_url,
        http_paths::POLICY_PROMOTE,
        json!({
            "canvas_id": active_canvas_id.clone(),
            "revision": saved_revision,
        }),
    )
    .await;
    assert_eq!(promote["document"]["mode"].as_str(), Some("enforced"));

    let audit = get_json(
        &client,
        &base_url,
        &format!(
            "{}?canvas_id={}",
            http_paths::POLICY_AUDIT,
            active_canvas_id
        ),
    )
    .await;
    assert_eq!(audit["active_revision"].as_u64(), Some(saved_revision));
    assert_eq!(audit["mode"].as_str(), Some("enforced"));
    assert_eq!(
        audit["latest_simulation"]["revision"].as_u64(),
        Some(saved_revision)
    );

    server.abort();
    let _ = server.await;
}

async fn run_task_board_http_plan_revoke_flow() {
    let state = test_http_state_with_db();
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();

    seed_ready_board_item(&state, "board-revoke-1", "Revoke me").await;
    let path = http_paths::TASK_BOARD_PLAN_REVOKE.replace("{item_id}", "board-revoke-1");
    let response = post_json(&client, &base_url, &path, json!({})).await;

    assert_eq!(response["item"]["status"].as_str(), Some("agentic_review"));
    assert_eq!(
        response["item"]["planning"]["summary"].as_str(),
        Some("Use task dispatch.")
    );
    assert!(response["item"]["planning"]["approved_by"].is_null());
    assert!(response["item"]["planning"]["approved_at"].is_null());

    let stored = state
        .async_db
        .get()
        .expect("async db")
        .task_board_item("board-revoke-1")
        .await
        .expect("load board item");
    assert_eq!(stored.status, TaskBoardStatus::AgenticReview);
    assert_eq!(
        stored.planning.summary.as_deref(),
        Some("Use task dispatch.")
    );
    assert!(stored.planning.approved_by.is_none());
    assert!(stored.planning.approved_at.is_none());

    server.abort();
    let _ = server.await;
}

async fn run_task_board_http_catalog_flow() {
    let state = test_http_state_with_db();
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();

    seed_catalog_board_item(
        &state,
        "board-http-catalog-a",
        "HTTP catalog alpha todo",
        "project-alpha",
        AgentMode::Planning,
        TaskBoardStatus::Todo,
    )
    .await;
    seed_catalog_board_item(
        &state,
        "board-http-catalog-b",
        "HTTP catalog alpha running",
        "project-alpha",
        AgentMode::Planning,
        TaskBoardStatus::InProgress,
    )
    .await;
    seed_catalog_board_item(
        &state,
        "board-http-catalog-c",
        "HTTP catalog beta todo",
        "project-beta",
        AgentMode::Evaluate,
        TaskBoardStatus::Todo,
    )
    .await;

    let projects = get_json(&client, &base_url, http_paths::TASK_BOARD_PROJECTS).await;
    assert_project_summary(&projects, "project-alpha", 2, 1);
    assert_project_summary(&projects, "project-beta", 1, 1);

    let todo_projects = get_json(
        &client,
        &base_url,
        &format!("{}?status=todo", http_paths::TASK_BOARD_PROJECTS),
    )
    .await;
    assert_project_summary(&todo_projects, "project-alpha", 1, 1);
    assert_project_summary(&todo_projects, "project-beta", 1, 1);

    let machines = get_json(&client, &base_url, http_paths::TASK_BOARD_MACHINES).await;
    assert_machine_summary(&machines, "planning", 2, 1);
    assert_machine_summary(&machines, "evaluate", 1, 1);

    let todo_machines = get_json(
        &client,
        &base_url,
        &format!("{}?status=todo", http_paths::TASK_BOARD_MACHINES),
    )
    .await;
    assert_machine_summary(&todo_machines, "planning", 1, 1);
    assert_machine_summary(&todo_machines, "evaluate", 1, 1);

    server.abort();
    let _ = server.await;
}
