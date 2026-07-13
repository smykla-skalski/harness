use tempfile::tempdir;

use crate::daemon::db::AsyncDaemonDb;
use crate::reviews::{
    ReviewAuthorAssociation, ReviewCheckStatus, ReviewItem, ReviewMergeableState,
    ReviewPullRequestState, ReviewReviewStatus, ReviewsQueryRequest, ReviewsQueryResponse,
    ReviewsRefreshRequest,
};
use crate::task_board::{
    ExternalRef, ExternalRefProvider, ExternalRefSyncState, TaskBoardGitHubInboxConfig,
    TaskBoardItem, TaskBoardOrchestratorSettings, TaskBoardStatus,
};

use super::super::{
    cached_query_response, query_reviews_repositories_source, query_reviews_with_database,
    refresh::reconcile_targeted_missing_task_board_reviews, store_cached_query_response,
};
use super::parsed;

#[path = "projection/eligibility.rs"]
mod eligibility;

fn one_repo_item(repository: &str, pr_id: &str) -> ReviewItem {
    ReviewItem {
        pull_request_id: pr_id.into(),
        repository_id: format!("{repository}#repo_id"),
        repository: repository.into(),
        number: 1,
        title: "chore(deps): bump".into(),
        url: format!("https://example.com/{pr_id}"),
        base_ref_name: None,
        default_branch_name: None,
        backport_source: None,
        author_login: "renovate[bot]".into(),
        author_avatar_url: None,
        author_association: ReviewAuthorAssociation::None,
        state: ReviewPullRequestState::Open,
        mergeable: ReviewMergeableState::Mergeable,
        review_status: ReviewReviewStatus::ReviewRequired,
        check_status: ReviewCheckStatus::Success,
        flags: crate::reviews::ReviewItemFlags {
            policy_blocked: false,
            is_draft: false,
            viewer_can_update: true,
            viewer_is_requested_reviewer: false,
        },
        viewer_can_merge_as_admin: false,
        head_sha: "abc123".into(),
        labels: Vec::new(),
        checks: Vec::new(),
        reviews: Vec::new(),
        additions: 1,
        deletions: 1,
        created_at: parsed("2026-05-20T12:00:00Z"),
        updated_at: parsed("2026-05-20T12:00:00Z"),
        required_failed_check_names: Vec::new(),
        required_approving_review_count: None,
        has_conflict_markers: None,
        viewer_has_active_approval: None,
        auto_merge_enabled: None,
        approval_requirement_satisfied_after_viewer_approval: None,
    }
}

fn base_request_with_authors(authors: &[&str]) -> ReviewsQueryRequest {
    ReviewsQueryRequest {
        authors: authors.iter().map(|a| (*a).to_string()).collect(),
        organizations: vec!["acme".into()],
        repositories: vec!["acme/api".into(), "acme/web".into()],
        exclude_repositories: vec!["acme/legacy".into()],
        force_refresh: false,
        cache_max_age_seconds: 600,
        ..ReviewsQueryRequest::default()
    }
}

#[test]
fn repository_only_request_strips_orgs_and_keeps_excludes() {
    let request = base_request_with_authors(&["per-repo-strip-author"]);
    let scoped = request.repository_only_request("acme/api");

    assert_eq!(scoped.authors, vec!["per-repo-strip-author".to_string()]);
    assert!(scoped.organizations.is_empty());
    assert_eq!(scoped.repositories, vec!["acme/api".to_string()]);
    assert_eq!(scoped.exclude_repositories, vec!["acme/legacy".to_string()]);
    assert_eq!(scoped.force_refresh, request.force_refresh);
    assert_eq!(
        scoped.cache_max_age_seconds,
        request.cache_max_age_seconds()
    );
}

#[test]
fn cache_key_isolates_per_repo_requests() {
    let request = base_request_with_authors(&["per-repo-key-author"]);
    let scoped_a = request.repository_only_request("acme/api");
    let scoped_b = request.repository_only_request("acme/web");

    assert_ne!(
        scoped_a.cache_key(),
        scoped_b.cache_key(),
        "per-repo requests must hash to distinct cache keys"
    );
    assert_ne!(
        scoped_a.cache_key(),
        request.cache_key(),
        "one-repo cache key must differ from the multi-repo bulk key"
    );
}

#[test]
fn cached_query_response_returns_only_its_repo_bucket() {
    let request = base_request_with_authors(&["per-repo-cache-author"]);
    let scoped_a = request.repository_only_request("acme/api");
    let scoped_b = request.repository_only_request("acme/web");

    let response_a = ReviewsQueryResponse::new(
        vec![one_repo_item("acme/api", "pr_iso_a")],
        "2026-05-21T00:00:00Z".into(),
    );
    let response_b = ReviewsQueryResponse::new(
        vec![one_repo_item("acme/web", "pr_iso_b")],
        "2026-05-21T00:00:00Z".into(),
    );
    store_cached_query_response(scoped_a.cache_key(), &response_a);
    store_cached_query_response(scoped_b.cache_key(), &response_b);

    let hit_a = cached_query_response(&scoped_a.cache_key(), 600).expect("cache hit for acme/api");
    let hit_b = cached_query_response(&scoped_b.cache_key(), 600).expect("cache hit for acme/web");

    assert_eq!(hit_a.items.len(), 1);
    assert_eq!(hit_a.items[0].repository, "acme/api");
    assert_eq!(hit_a.items[0].pull_request_id, "pr_iso_a");
    assert!(hit_a.from_cache);

    assert_eq!(hit_b.items.len(), 1);
    assert_eq!(hit_b.items[0].repository, "acme/web");
    assert_eq!(hit_b.items[0].pull_request_id, "pr_iso_b");
    assert!(hit_b.from_cache);
}

#[tokio::test]
async fn repository_source_aggregate_reuses_canonical_per_repository_buckets() {
    let _github_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let request = base_request_with_authors(&["per-repo-aggregate-author"]);
    for (repository, pull_request_id) in [
        ("acme/api", "pr_aggregate_a"),
        ("acme/web", "pr_aggregate_b"),
    ] {
        let scoped = request.repository_only_request(repository);
        store_cached_query_response(
            scoped.cache_key(),
            &ReviewsQueryResponse::new(
                vec![one_repo_item(repository, pull_request_id)],
                "2026-05-21T00:00:00Z".into(),
            ),
        );
    }

    let source = query_reviews_repositories_source(&request)
        .await
        .expect("aggregate cached repository sources");

    assert!(source.response.from_cache);
    assert_eq!(
        source
            .response
            .items
            .iter()
            .map(|item| item.pull_request_id.as_str())
            .collect::<Vec<_>>(),
        vec!["pr_aggregate_a", "pr_aggregate_b"]
    );
}

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
    assert_eq!(items[0].status, TaskBoardStatus::Todo);
    assert_eq!(items[0].project_id.as_deref(), Some("acme/api"));
    assert_eq!(
        items[0].external_refs[0].external_id, "acme/api#17",
        "repeated projection must reuse the deterministic imported item"
    );
}

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
        TaskBoardStatus::Umbrella,
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
    assert_eq!(updated.status, TaskBoardStatus::Todo);
}

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

#[tokio::test]
async fn targeted_missing_refresh_completes_only_matching_imported_review() {
    let _github_guard = crate::github_api::acquire_global_budget_test_lock().await;
    let dir = tempdir().expect("tempdir");
    let db = AsyncDaemonDb::connect(&dir.path().join("harness.db"))
        .await
        .expect("open database");
    create_imported_review(&db, "missing-review", "acme/api", 31).await;
    create_imported_review(&db, "unrelated-review", "acme/api", 32).await;
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
    assert_eq!(unrelated.status, TaskBoardStatus::HumanRequired);
    assert_eq!(
        unrelated.external_refs[0]
            .sync_state
            .as_ref()
            .and_then(|state| state.status),
        Some(TaskBoardStatus::HumanRequired)
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

async fn create_imported_review(db: &AsyncDaemonDb, item_id: &str, repository: &str, number: u64) {
    let mut item = TaskBoardItem::new(
        item_id.to_owned(),
        format!("Review {repository}#{number}"),
        String::new(),
        "2026-07-11T12:00:00Z".into(),
    );
    item.status = TaskBoardStatus::HumanRequired;
    item.project_id = Some(repository.to_owned());
    item.imported_from_provider = Some(ExternalRefProvider::GitHub);
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: format!("{repository}#{number}"),
        url: Some(format!("https://github.com/{repository}/pull/{number}")),
        sync_state: Some(ExternalRefSyncState {
            status: Some(TaskBoardStatus::HumanRequired),
            updated_at: Some("2026-07-11T12:00:00Z".into()),
            ..ExternalRefSyncState::default()
        }),
    }];
    db.create_task_board_item(item)
        .await
        .expect("create imported review");
}

fn cached_projection_request(repository: &str) -> ReviewsQueryRequest {
    ReviewsQueryRequest {
        repositories: vec![repository.to_owned()],
        cache_max_age_seconds: 600,
        ..ReviewsQueryRequest::default()
    }
}

fn requested_review_item(
    repository: &str,
    pull_request_id: &str,
    number: u64,
    labels: &[&str],
) -> ReviewItem {
    let mut item = one_repo_item(repository, pull_request_id);
    item.number = number;
    item.title = format!("Review {repository}#{number}");
    item.url = format!("https://github.com/{repository}/pull/{number}");
    item.flags.viewer_is_requested_reviewer = true;
    item.labels = labels.iter().map(|label| (*label).to_owned()).collect();
    item
}

async fn configure_review_inbox(db: &AsyncDaemonDb, repositories: &[&str], labels: &[&str]) {
    let settings = TaskBoardOrchestratorSettings {
        github_inbox: TaskBoardGitHubInboxConfig {
            repositories: repositories
                .iter()
                .map(|repository| (*repository).to_owned())
                .collect(),
            label_filter: labels.iter().map(|label| (*label).to_owned()).collect(),
        },
        ..TaskBoardOrchestratorSettings::default()
    };
    db.replace_task_board_orchestrator_settings(&settings)
        .await
        .expect("configure review inbox");
}
