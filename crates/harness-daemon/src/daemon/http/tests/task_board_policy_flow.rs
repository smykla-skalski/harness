use super::*;

pub(super) async fn run_task_board_http_policy_pipeline_flow() {
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
    assert_eq!(promote["revision"].as_u64(), Some(saved_revision));

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

pub(super) async fn run_task_board_http_plan_revoke_flow() {
    let state = test_http_state_with_db();
    let (base_url, server) = serve_http(state.clone()).await;
    let client = reqwest::Client::new();

    Box::pin(seed_ready_board_item(&state, "board-revoke-1", "Revoke me")).await;
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
