//! Delivery renders the worker prompt, and the item is editable for as long as
//! the dispatch is held. These pin the two things that follow: the render that
//! decides has to see the state the claim commits, and the prompt the response
//! reports has to be the one the agent was started with.

use serde_json::{Value, json};
use tempfile::tempdir;

use crate::daemon::protocol::http_paths;
use crate::task_board::prompt_catalog::{
    PromptCatalog, prompt_catalog_test_lock, scoped_prompt_catalog,
};

use super::task_board_support::*;
use super::*;

const DELIVER_PATH: &str = "/v1/task-board/dispatch/deliver";

/// The held payload still names a body this item no longer has. Rendering the
/// held payload therefore succeeds while rendering the state the claim commits
/// fails, which is the whole point: the deciding render must be the second one,
/// and refusing it must leave the dispatch exactly as it was.
#[test]
fn an_edit_during_hold_that_breaks_the_prompt_leaves_the_dispatch_deliverable() {
    let sandbox = tempdir().expect("tempdir");
    without_durable_task_board_automation(|| {
        harness_testkit::with_isolated_harness_env(sandbox.path(), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(run_broken_edit_during_hold(sandbox.path()));
        });
    });
}

async fn run_broken_edit_during_hold(sandbox: &std::path::Path) {
    let _lock = prompt_catalog_test_lock();
    let project_dir = sandbox.join("deliver-broken-project");
    harness_testkit::init_git_repo_with_seed(&project_dir);
    let (state, base_url, server, client) = held_step_mode_item(&project_dir, "board-deliver-broken").await;

    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"worker": "Work on {{ task_body }}"}"#)
            .expect("parse overrides"),
    );
    // `task_body` is only available while the body is non-empty, so blanking it
    // is an ordinary edit that makes the claimed state unrenderable.
    put_json(
        &client,
        &base_url,
        "/v1/task-board/items/board-deliver-broken",
        json!({ "body": "   " }),
    )
    .await;

    let (status, refused) = post_json_raw(
        &client,
        &base_url,
        DELIVER_PATH,
        json!({ "item_id": "board-deliver-broken" }),
    )
    .await;

    assert_ne!(
        status,
        StatusCode::OK,
        "an unrenderable claimed state must refuse delivery, got {refused}"
    );
    assert_eq!(
        held_dispatch_count(&client, &base_url).await,
        Some(1),
        "a refused render must leave the dispatch held"
    );

    // The strongest proof the claim was rolled back rather than consumed: put
    // the body back and the very same dispatch delivers.
    put_json(
        &client,
        &base_url,
        "/v1/task-board/items/board-deliver-broken",
        json!({ "body": "Create a daemon integration task." }),
    )
    .await;
    let delivered = post_json(
        &client,
        &base_url,
        DELIVER_PATH,
        json!({ "item_id": "board-deliver-broken" }),
    )
    .await;
    assert!(
        delivered["started_agent"].is_object(),
        "the repaired dispatch must still be deliverable: {delivered}"
    );

    drop(state);
    server.abort();
    let _ = server.await;
}

/// The response's prompt is what the operator reads back, so it has to be the
/// text the agent actually received -- rendered from the item the claim
/// committed, not from the payload frozen when the dispatch was held.
#[test]
fn the_delivered_prompt_is_the_one_the_started_agent_received() {
    let sandbox = tempdir().expect("tempdir");
    without_durable_task_board_automation(|| {
        harness_testkit::with_isolated_harness_env(sandbox.path(), || {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(run_edit_during_hold_reports_started_prompt(sandbox.path()));
        });
    });
}

async fn run_edit_during_hold_reports_started_prompt(sandbox: &std::path::Path) {
    let _lock = prompt_catalog_test_lock();
    let project_dir = sandbox.join("deliver-edited-project");
    harness_testkit::init_git_repo_with_seed(&project_dir);
    let (state, base_url, server, client) = held_step_mode_item(&project_dir, "board-deliver-edited").await;

    let _installed = scoped_prompt_catalog(
        PromptCatalog::from_json(br#"{"worker": "Work on {{ title }}"}"#).expect("parse overrides"),
    );
    put_json(
        &client,
        &base_url,
        "/v1/task-board/items/board-deliver-edited",
        json!({ "title": "Edited while held" }),
    )
    .await;

    let delivered = post_json(
        &client,
        &base_url,
        DELIVER_PATH,
        json!({ "item_id": "board-deliver-edited" }),
    )
    .await;

    assert!(delivered["started_agent"].is_object(), "{delivered}");
    assert_eq!(
        delivered["applied"]["item"]["title"].as_str(),
        Some("Edited while held"),
        "the claim commits the edited item"
    );
    assert_eq!(
        delivered["rendered_prompt"].as_str(),
        Some("Work on Edited while held"),
        "the reported prompt must be the one the agent ran with, not the held payload's"
    );

    drop(state);
    server.abort();
    let _ = server.await;
}

/// Drive an item to a held dispatch through step mode, the way an operator
/// reaches one.
async fn held_step_mode_item(
    project_dir: &std::path::Path,
    item_id: &str,
) -> (
    DaemonHttpState,
    String,
    tokio::task::JoinHandle<()>,
    reqwest::Client,
) {
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
    seed_ready_board_item(&state, item_id, "Held delivery item").await;
    let response = dispatch_http_item(&client, &base_url, item_id, project_dir).await;
    assert_eq!(
        first_applied(&response)["item"]["workflow"]["current_step_id"].as_str(),
        Some("awaiting_delivery")
    );
    (state, base_url, server, client)
}

async fn held_dispatch_count(client: &reqwest::Client, base_url: &str) -> Option<u64> {
    get_json(
        client,
        base_url,
        http_paths::TASK_BOARD_ORCHESTRATOR_STATUS,
    )
    .await["held_dispatches"]["count"]
        .as_u64()
}

async fn allow_fallback_spawn_for_test(state: &DaemonHttpState) {
    let mut workspace = crate::task_board::policy_graph::PolicyCanvasWorkspace::seeded();
    workspace.spawn_requires_live_policy = false;
    state
        .async_db
        .get()
        .expect("test async db")
        .replace_policy_workspace(&workspace)
        .await
        .expect("configure explicit test fallback");
}

async fn post_json_raw(
    client: &reqwest::Client,
    base_url: &str,
    path: &str,
    body: Value,
) -> (StatusCode, Value) {
    let response = client
        .post(format!("{base_url}{path}"))
        .bearer_auth("token")
        .json(&body)
        .send()
        .await
        .expect("send request");
    let status = response.status();
    let value = response.json::<Value>().await.expect("json response");
    (status, value)
}
