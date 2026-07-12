use super::*;

#[tokio::test]
async fn observed_label_and_repository_eligibility_loss_completes_only_matching_tasks() {
    let _github_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
    let api_request = cached_projection_request("eligibility/api");
    let web_request = cached_projection_request("eligibility/web");
    configure_review_inbox(
        &db,
        &["eligibility/api", "eligibility/web"],
        &["task-board"],
    )
    .await;
    cache_requested_review(
        &api_request,
        "eligibility/api",
        "pr_eligibility_api",
        41,
        &["task-board"],
    );
    cache_requested_review(
        &web_request,
        "eligibility/web",
        "pr_eligibility_web",
        42,
        &["task-board"],
    );
    query_reviews_with_database(&api_request, Some(&db))
        .await
        .expect("project api review");
    query_reviews_with_database(&web_request, Some(&db))
        .await
        .expect("project web review");

    cache_requested_review(
        &api_request,
        "eligibility/api",
        "pr_eligibility_api",
        41,
        &["docs"],
    );
    query_reviews_with_database(&api_request, Some(&db))
        .await
        .expect("project api label loss");
    let after_label_loss = db.list_task_board_items(None).await.expect("list board");
    assert_eq!(
        status_for_repository(&after_label_loss, "eligibility/api"),
        TaskBoardStatus::Done
    );
    assert_eq!(
        status_for_repository(&after_label_loss, "eligibility/web"),
        TaskBoardStatus::HumanRequired,
        "a per-repository observation must not globally stale unrelated tasks"
    );

    configure_review_inbox(&db, &["eligibility/api"], &["task-board"]).await;
    query_reviews_with_database(&web_request, Some(&db))
        .await
        .expect("project web repository loss");
    let after_repository_loss = db.list_task_board_items(None).await.expect("list board");
    assert_eq!(
        status_for_repository(&after_repository_loss, "eligibility/web"),
        TaskBoardStatus::Done
    );
}

fn cache_requested_review(
    request: &ReviewsQueryRequest,
    repository: &str,
    pull_request_id: &str,
    number: u64,
    labels: &[&str],
) {
    store_cached_query_response(
        request.cache_key(),
        &ReviewsQueryResponse::new(
            vec![requested_review_item(
                repository,
                pull_request_id,
                number,
                labels,
            )],
            "2026-07-11T12:05:00Z".into(),
        ),
    );
}

fn status_for_repository(items: &[TaskBoardItem], repository: &str) -> TaskBoardStatus {
    items
        .iter()
        .find(|item| item.project_id.as_deref() == Some(repository))
        .unwrap_or_else(|| panic!("missing task for {repository}"))
        .status
}
