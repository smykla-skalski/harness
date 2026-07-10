use std::path::Path;

use serde_json::json;
use tempfile::tempdir;

use crate::daemon::protocol::http_paths;
use crate::task_board::{AgentMode, TaskBoardStatus, TaskBoardStore, default_board_root};

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
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();

    run_task_board_http_item_scope_flow(&client, &base_url, &state, &project_dir).await;
    run_task_board_http_run_once_flow(&client, &base_url, &state, &project_dir).await;

    server.abort();
    let _ = server.await;
}

async fn run_task_board_http_item_scope_flow(
    client: &reqwest::Client,
    base_url: &str,
    state: &crate::daemon::http::DaemonHttpState,
    project_dir: &Path,
) {
    seed_ready_board_item("board-http-dispatch", "HTTP dispatch item");
    seed_ready_board_item("board-http-dispatch-other", "HTTP dispatch other item");
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
    assert_codex_worker_started(state, &session_id, "board-http-dispatch", &work_item_id);
    assert_board_item_unlinked("board-http-dispatch-other");
    let other_dispatch =
        dispatch_http_item(client, base_url, "board-http-dispatch-other", project_dir).await;
    let other_applied = first_applied(&other_dispatch);
    let other_session_id = required_string(other_applied, "session_id");
    let other_work_item_id = required_string(other_applied, "work_item_id");
    join_leader(state, &session_id, project_dir).await;
    join_leader(state, &other_session_id, project_dir).await;

    mark_http_task_done(client, base_url, &session_id, &work_item_id).await;
    mark_http_task_done(client, base_url, &other_session_id, &other_work_item_id).await;
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
    assert_eq!(evaluation["updated"].as_u64(), Some(1));
    assert_eq!(evaluation["completed"].as_u64(), Some(1));
    assert_eq!(
        evaluation["records"][0]["item"]["workflow"]["status"].as_str(),
        Some("completed")
    );
    assert_eq!(
        evaluation["records"][0]["board_item_id"].as_str(),
        Some("board-http-dispatch")
    );
    assert_board_item_status("board-http-dispatch", TaskBoardStatus::Done);
    assert_board_item_status("board-http-dispatch-other", TaskBoardStatus::InProgress);
}

async fn run_task_board_http_run_once_flow(
    client: &reqwest::Client,
    base_url: &str,
    state: &crate::daemon::http::DaemonHttpState,
    project_dir: &Path,
) {
    seed_ready_board_item("board-http-run-once", "HTTP run once item");
    seed_ready_board_item("board-http-run-once-other", "HTTP run once other item");
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
    assert_codex_worker_started(
        state,
        &required_string(applied, "session_id"),
        "board-http-run-once",
        &required_string(applied, "work_item_id"),
    );
    assert_board_item_unlinked("board-http-run-once-other");
}

async fn run_task_board_http_policy_pipeline_flow() {
    let state = test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
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
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    seed_ready_board_item("board-revoke-1", "Revoke me");
    let path = http_paths::TASK_BOARD_PLAN_REVOKE.replace("{item_id}", "board-revoke-1");
    let response = post_json(&client, &base_url, &path, json!({})).await;

    assert_eq!(response["item"]["status"].as_str(), Some("agentic_review"));
    assert_eq!(
        response["item"]["planning"]["summary"].as_str(),
        Some("Use task dispatch.")
    );
    assert!(response["item"]["planning"]["approved_by"].is_null());
    assert!(response["item"]["planning"]["approved_at"].is_null());

    let stored = TaskBoardStore::new(default_board_root())
        .get("board-revoke-1")
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
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    seed_catalog_board_item(
        "board-http-catalog-a",
        "HTTP catalog alpha todo",
        "project-alpha",
        AgentMode::Planning,
        TaskBoardStatus::Todo,
    );
    seed_catalog_board_item(
        "board-http-catalog-b",
        "HTTP catalog alpha running",
        "project-alpha",
        AgentMode::Planning,
        TaskBoardStatus::InProgress,
    );
    seed_catalog_board_item(
        "board-http-catalog-c",
        "HTTP catalog beta todo",
        "project-beta",
        AgentMode::Evaluate,
        TaskBoardStatus::Todo,
    );

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
