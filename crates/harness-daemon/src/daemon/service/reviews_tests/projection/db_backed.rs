use super::*;
use crate::daemon::db::AsyncAuditQueries;

// Held across every await in this test deliberately: the shared GitHub API budget state guards a
// process-global test resource, and the exclusivity has to span the whole
// test body, not just the acquire call, or two tests could interleave.
#[allow(clippy::await_holding_lock)]
#[tokio::test]
async fn cached_reviews_query_creates_only_matching_task_board_reviews_idempotently() {
    let _github_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
    configure_review_inbox(&db, &["acme/api"], &["task-board"]).await;
    let request = cached_projection_request("acme/api");
    let response = ReviewsQueryResponse::new(
        vec![
            requested_review_item("acme/api", "pr_projected", 17, &["task-board"]),
            requested_review_item("acme/api", "pr_filtered_label", 18, &["docs"]),
            requested_review_item("acme/other", "pr_filtered_repo", 19, &["task-board"]),
        ],
        "2026-07-11T12:00:00Z".into(),
    );
    store_cached_query_response(request.cache_key(), &response);

    let first = query_reviews_with_database(&request, Some(&db))
        .await
        .expect("project cached query");
    let revision_after_first = db.task_board_revision().await.expect("first revision");
    let second = query_reviews_with_database(&request, Some(&db))
        .await
        .expect("project cached query again");
    let revision_after_second = db.task_board_revision().await.expect("second revision");
    let items = db.list_task_board_items(None).await.expect("list board");

    assert!(first.from_cache);
    assert!(second.from_cache);
    assert_eq!(revision_after_second, revision_after_first);
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].title, "Review acme/api#17");
    assert_eq!(items[0].status, TaskBoardStatus::Inbox);
    assert!(items[0].project_id.is_none());
    assert_eq!(items[0].execution_repository.as_deref(), Some("acme/api"));
    assert_eq!(
        items[0].external_refs[0].external_id, "acme/api#17",
        "repeated projection must reuse the deterministic imported item"
    );
}

// Held across every await in this test deliberately: the shared GitHub API budget state guards a
// process-global test resource, and the exclusivity has to span the whole
// test body, not just the acquire call, or two tests could interleave.
#[allow(clippy::await_holding_lock)]
#[tokio::test]
async fn cached_reviews_projection_preserves_user_selected_status() {
    let _github_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
    configure_review_inbox(&db, &["status/preserved"], &[]).await;
    let request = cached_projection_request("status/preserved");
    let response = ReviewsQueryResponse::new(
        vec![requested_review_item(
            "status/preserved",
            "pr_status_preserved",
            31,
            &[],
        )],
        "2026-07-11T12:00:00Z".into(),
    );
    store_cached_query_response(request.cache_key(), &response);
    query_reviews_with_database(&request, Some(&db))
        .await
        .expect("initial cached projection");
    let item = db.list_task_board_items(None).await.expect("list board")[0].clone();
    for status in [
        TaskBoardStatus::Inbox,
        TaskBoardStatus::Todo,
        TaskBoardStatus::Planning,
        TaskBoardStatus::InProgress,
        TaskBoardStatus::AgenticReview,
        TaskBoardStatus::Testing,
        TaskBoardStatus::InReview,
        TaskBoardStatus::ToReview,
        TaskBoardStatus::HumanRequired,
        TaskBoardStatus::Failed,
        TaskBoardStatus::Done,
    ] {
        db.update_task_board_item(&item.id, |current| {
            current.status = status;
            current.planning.summary = Some("Review the dependency update".to_owned());
            Ok(true)
        })
        .await
        .expect("select local task status");

        let projected = query_reviews_with_database(&request, Some(&db))
            .await
            .expect("repeat cached projection");
        let updated = db.task_board_item(&item.id).await.expect("load task");

        assert!(projected.from_cache);
        assert_eq!(updated.status, status, "sync must preserve the local lane");
    }
    let updated = db.task_board_item(&item.id).await.expect("load task");
    assert_eq!(
        updated.planning.summary.as_deref(),
        Some("Review the dependency update")
    );
}

// Held across every await in this test deliberately: the shared GitHub API budget state guards a
// process-global test resource, and the exclusivity has to span the whole
// test body, not just the acquire call, or two tests could interleave.
#[allow(clippy::await_holding_lock)]
#[tokio::test]
async fn cached_reviews_projection_reopens_done_task_when_review_is_requested_again() {
    let _github_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
    configure_review_inbox(&db, &["status/reopened"], &[]).await;
    let request = cached_projection_request("status/reopened");
    let review = requested_review_item("status/reopened", "pr_status_reopened", 32, &[]);
    let refresh_request = ReviewsRefreshRequest {
        targets: vec![review.target()],
        ..ReviewsRefreshRequest::default()
    };
    let response = ReviewsQueryResponse::new(vec![review], "2026-07-11T12:00:00Z".into());
    store_cached_query_response(request.cache_key(), &response);
    query_reviews_with_database(&request, Some(&db))
        .await
        .expect("initial cached projection");
    let item = db.list_task_board_items(None).await.expect("list board")[0].clone();
    assert!(
        reconcile_targeted_missing_task_board_reviews(
            Some(&db),
            &refresh_request,
            &["pr_status_reopened".into()],
            crate::github_api::GitHubProtectedClient::data_revision(),
        )
        .await
        .expect("record external review completion")
    );
    let completed = db.task_board_item(&item.id).await.expect("load task");
    assert_eq!(completed.status, TaskBoardStatus::Done);

    let projected = query_reviews_with_database(&request, Some(&db))
        .await
        .expect("repeat cached projection");
    let updated = db.task_board_item(&item.id).await.expect("load task");

    assert!(projected.from_cache);
    assert_eq!(updated.status, TaskBoardStatus::Inbox);
}

// Held across every await in this test deliberately: the shared GitHub API budget state guards a
// process-global test resource, and the exclusivity has to span the whole
// test body, not just the acquire call, or two tests could interleave.
#[allow(clippy::await_holding_lock)]
#[tokio::test]
async fn failed_cached_projection_is_retried_without_refetching_reviews() {
    let _github_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let failed_dir = tempdir().expect("failed tempdir");
    let failed_db = AsyncDaemonDb::connect(&failed_dir.path().join("harness.db"))
        .await
        .expect("open failed database");
    configure_review_inbox(&failed_db, &["retry/project"], &[]).await;
    let request = cached_projection_request("retry/project");
    let response = ReviewsQueryResponse::new(
        vec![requested_review_item(
            "retry/project",
            "pr_cached_retry",
            23,
            &[],
        )],
        "2026-07-11T12:00:00Z".into(),
    );
    store_cached_query_response(request.cache_key(), &response);
    failed_db.pool().close().await;

    query_reviews_with_database(&request, Some(&failed_db))
        .await
        .expect_err("closed database must fail projection");

    let recovered_dir = tempdir().expect("recovered tempdir");
    let recovered_db = AsyncDaemonDb::connect(&recovered_dir.path().join("harness.db"))
        .await
        .expect("open recovered database");
    configure_review_inbox(&recovered_db, &["retry/project"], &[]).await;
    let retried = query_reviews_with_database(&request, Some(&recovered_db))
        .await
        .expect("retry cached projection");

    assert!(retried.from_cache);
    assert_eq!(
        recovered_db
            .list_task_board_items(None)
            .await
            .expect("list recovered board")
            .len(),
        1
    );
}

// Held across every await in this test deliberately: the shared GitHub API budget state guards a
// process-global test resource, and the exclusivity has to span the whole
// test body, not just the acquire call, or two tests could interleave.
#[allow(clippy::await_holding_lock)]
#[tokio::test]
async fn targeted_missing_refresh_completes_only_matching_imported_review() {
    let _github_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
    Box::pin(create_imported_review(
        &db,
        "missing-review",
        "acme/api",
        31,
    ))
    .await;
    Box::pin(create_imported_review(
        &db,
        "unrelated-review",
        "acme/api",
        32,
    ))
    .await;
    let missing = requested_review_item("acme/api", "pr_missing", 31, &[]);
    let unrelated = requested_review_item("acme/api", "pr_unrelated", 32, &[]);
    let request = ReviewsRefreshRequest {
        targets: vec![missing.target(), unrelated.target()],
        ..ReviewsRefreshRequest::default()
    };

    assert!(
        reconcile_targeted_missing_task_board_reviews(
            Some(&db),
            &request,
            &["pr_missing".into()],
            crate::github_api::GitHubProtectedClient::data_revision(),
        )
        .await
        .expect("reconcile missing review")
    );

    let completed = db
        .task_board_item("missing-review")
        .await
        .expect("completed item");
    let unrelated = db
        .task_board_item("unrelated-review")
        .await
        .expect("unrelated item");
    assert_eq!(completed.status, TaskBoardStatus::Done);
    assert_eq!(
        completed.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::Done)
    );
    assert_eq!(unrelated.status, TaskBoardStatus::Inbox);
    assert_eq!(
        unrelated.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::Inbox)
    );

    let revision_after_first = db.task_board_revision().await.expect("first revision");
    assert!(
        reconcile_targeted_missing_task_board_reviews(
            Some(&db),
            &request,
            &["pr_missing".into()],
            crate::github_api::GitHubProtectedClient::data_revision(),
        )
        .await
        .expect("repeat missing review reconciliation")
    );
    assert_eq!(
        db.task_board_revision().await.expect("second revision"),
        revision_after_first,
        "an unchanged missing review must not be rewritten"
    );
    let events = db
        .load_audit_events(&crate::daemon::protocol::HarnessMonitorAuditEventsRequest {
            action_keys: vec!["task_board.sync".into()],
            ..Default::default()
        })
        .await
        .expect("load sync audit events")
        .events;
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].outcome, "success");
    assert_eq!(
        events[0]
            .payload_json
            .as_ref()
            .and_then(|payload| payload["snapshot_update_count"].as_u64()),
        Some(1)
    );
}
