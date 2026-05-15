use std::path::Path;

use reqwest::StatusCode;
use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;

use crate::daemon::protocol::SessionJoinRequest;
use crate::daemon::protocol::http_paths;
use crate::daemon::service::join_session_direct_async;
use crate::session::types::SessionRole;
use crate::task_board::planning::{approve_plan, submit_plan};
use crate::task_board::{
    AgentMode, TaskBoardItem, TaskBoardStatus, TaskBoardStore, default_board_root,
};

use super::task_board_managed_worker_assertions::assert_codex_worker_started;
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

async fn dispatch_http_item(
    client: &reqwest::Client,
    base_url: &str,
    item_id: &str,
    project_dir: &Path,
) -> Value {
    post_json(
        client,
        base_url,
        http_paths::TASK_BOARD_DISPATCH,
        json!({
            "id": item_id,
            "status": "todo",
            "dry_run": false,
            "project_dir": project_dir,
        }),
    )
    .await
}

async fn mark_http_task_done(
    client: &reqwest::Client,
    base_url: &str,
    session_id: &str,
    work_item_id: &str,
) {
    post_json(
        client,
        base_url,
        &format!("/v1/sessions/{session_id}/tasks/{work_item_id}/status"),
        json!({
            "actor": "spoofed-client",
            "status": "done",
            "note": "completed by test"
        }),
    )
    .await;
}

async fn run_task_board_http_policy_pipeline_flow() {
    let state = test_http_state_with_db();
    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let pipeline = get_json(&client, &base_url, http_paths::TASK_BOARD_POLICY_PIPELINE).await;
    assert_eq!(pipeline["schema_version"].as_u64(), Some(2));
    assert_eq!(pipeline["mode"].as_str(), Some("draft"));

    let save = put_json(
        &client,
        &base_url,
        http_paths::TASK_BOARD_POLICY_PIPELINE,
        json!({ "document": pipeline }),
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
        http_paths::TASK_BOARD_POLICY_SIMULATE,
        json!({ "document": save["document"].clone() }),
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
        http_paths::TASK_BOARD_POLICY_PROMOTE,
        json!({ "revision": saved_revision }),
    )
    .await;
    assert_eq!(promote["document"]["mode"].as_str(), Some("enforced"));

    let audit = get_json(&client, &base_url, http_paths::TASK_BOARD_POLICY_AUDIT).await;
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

    assert_eq!(response["item"]["status"].as_str(), Some("plan_review"));
    assert_eq!(
        response["item"]["planning"]["summary"].as_str(),
        Some("Use task dispatch.")
    );
    assert!(response["item"]["planning"]["approved_by"].is_null());
    assert!(response["item"]["planning"]["approved_at"].is_null());

    let stored = TaskBoardStore::new(default_board_root())
        .get("board-revoke-1")
        .expect("load board item");
    assert_eq!(stored.status, TaskBoardStatus::PlanReview);
    assert_eq!(stored.planning.summary.as_deref(), Some("Use task dispatch."));
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

async fn join_leader(
    state: &crate::daemon::http::DaemonHttpState,
    session_id: &str,
    project_dir: &Path,
) {
    let async_db = state.async_db.get().expect("async db");
    join_session_direct_async(
        session_id,
        &SessionJoinRequest {
            runtime: "claude".into(),
            role: SessionRole::Leader,
            fallback_role: None,
            capabilities: Vec::new(),
            name: Some("leader".into()),
            project_dir: project_dir.to_string_lossy().into_owned(),
            persona: None,
        },
        async_db.as_ref(),
    )
    .await
    .expect("join leader");
}

async fn serve_http(state: crate::daemon::http::DaemonHttpState) -> (String, JoinHandle<()>) {
    let app = super::super::daemon_http_router().with_state(state);
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind listener");
    let addr = listener.local_addr().expect("listener addr");
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.expect("serve router");
    });
    (format!("http://{addr}"), server)
}

async fn post_json(client: &reqwest::Client, base_url: &str, path: &str, body: Value) -> Value {
    let response = client
        .post(format!("{base_url}{path}"))
        .bearer_auth("token")
        .json(&body)
        .send()
        .await
        .expect("send request");
    let status = response.status();
    let value = response.json::<Value>().await.expect("json response");
    assert_eq!(status, StatusCode::OK, "{path} returned {value}");
    value
}

async fn put_json(client: &reqwest::Client, base_url: &str, path: &str, body: Value) -> Value {
    let response = client
        .put(format!("{base_url}{path}"))
        .bearer_auth("token")
        .json(&body)
        .send()
        .await
        .expect("send request");
    let status = response.status();
    let value = response.json::<Value>().await.expect("json response");
    assert_eq!(status, StatusCode::OK, "{path} returned {value}");
    value
}

async fn get_json(client: &reqwest::Client, base_url: &str, path: &str) -> Value {
    let response = client
        .get(format!("{base_url}{path}"))
        .bearer_auth("token")
        .send()
        .await
        .expect("send request");
    let status = response.status();
    let value = response.json::<Value>().await.expect("json response");
    assert_eq!(status, StatusCode::OK, "{path} returned {value}");
    value
}

fn seed_ready_board_item(id: &str, title: &str) {
    let store = TaskBoardStore::new(default_board_root());
    let mut item = TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        "Create a daemon integration task.".to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = TaskBoardStatus::Todo;
    let item = submit_plan(&item, "Use task dispatch.").apply_to(&item);
    let item = approve_plan(&item, "lead", "2026-05-14T01:00:00Z").apply_to(&item);
    let title = item.title.clone();
    let body = item.body.clone();
    store.create(&title, &body, item).expect("create item");
}

fn seed_catalog_board_item(
    id: &str,
    title: &str,
    project_id: &str,
    agent_mode: AgentMode,
    status: TaskBoardStatus,
) {
    let store = TaskBoardStore::new(default_board_root());
    let mut item = TaskBoardItem::new(
        id.to_string(),
        title.to_string(),
        "Create a daemon catalog task.".to_string(),
        "2026-05-14T00:00:00Z".to_string(),
    );
    item.status = status;
    item.project_id = Some(project_id.to_string());
    item.agent_mode = agent_mode;
    let title = item.title.clone();
    let body = item.body.clone();
    store.create(&title, &body, item).expect("create item");
}

fn assert_project_summary(value: &Value, project_id: &str, item_count: u64, ready_count: u64) {
    let summary = value
        .as_array()
        .and_then(|projects| {
            projects
                .iter()
                .find(|summary| summary["project_id"].as_str() == Some(project_id))
        })
        .unwrap_or_else(|| panic!("missing project summary {project_id}: {value}"));
    assert_eq!(summary["item_count"].as_u64(), Some(item_count));
    assert_eq!(summary["ready_count"].as_u64(), Some(ready_count));
}

fn assert_machine_summary(value: &Value, mode: &str, item_count: u64, ready_count: u64) {
    let summary = value
        .as_array()
        .and_then(|machines| {
            machines
                .iter()
                .find(|summary| summary["mode"].as_str() == Some(mode))
        })
        .unwrap_or_else(|| panic!("missing machine summary {mode}: {value}"));
    assert_eq!(summary["item_count"].as_u64(), Some(item_count));
    assert_eq!(summary["ready_count"].as_u64(), Some(ready_count));
}

fn first_applied(value: &Value) -> &Value {
    value["applied"]
        .as_array()
        .and_then(|applied| applied.first())
        .expect("first applied task")
}

fn assert_board_item_unlinked(id: &str) {
    let item = TaskBoardStore::new(default_board_root())
        .get(id)
        .expect("load board item");
    assert_eq!(item.status, TaskBoardStatus::Todo);
    assert!(item.work_item_id.is_none());
}

fn assert_board_item_status(id: &str, status: TaskBoardStatus) {
    let item = TaskBoardStore::new(default_board_root())
        .get(id)
        .expect("load board item");
    assert_eq!(item.status, status);
}

fn required_string(value: &Value, key: &str) -> String {
    value[key].as_str().expect("string field").to_string()
}

fn evaluation_records_contain(value: &Value, board_item_id: &str) -> bool {
    value["last_run"]["evaluation"]["records"]
        .as_array()
        .is_some_and(|records| {
            records
                .iter()
                .any(|record| record["board_item_id"].as_str() == Some(board_item_id))
        })
}
