use serde_json::json;

use super::*;
use crate::external::github::search_label_matches_filter;
use crate::types::{TaskBoardStatus, TaskBoardWorkflowKind};
use harness_github_api::acquire_global_budget_test_lock;

mod batch;
mod support;
use support::{
    MockResponse, assigned_only_inbox_client, empty_search_response, inbox_client_with_base_uri,
    search_response_with_issue, search_response_with_issue_body, search_response_with_issue_state,
    search_response_with_pull_request, spawn_sequence_mock, viewer_response,
};

#[test]
fn github_inbox_search_queries_use_github_all_state_issue_form() {
    let repository = parse_github_repository("owner/repo").expect("repository");
    let assigned_query = assigned_issue_query(&repository, "octo-user");

    assert_eq!(
        assigned_query,
        "repo:owner/repo is:issue assignee:octo-user state:open state:closed sort:updated-desc"
    );
    assert_eq!(
        review_request_query(&repository, "octo-user"),
        "repo:owner/repo is:pr review-requested:octo-user state:open sort:updated-desc"
    );
    assert_eq!(
        dependency_author_query(&repository, "renovate[bot]"),
        "repo:owner/repo is:pr is:open author:renovate[bot] sort:updated-desc"
    );
    assert_eq!(
        dependency_author_query(&repository, "dependabot[bot]"),
        "repo:owner/repo is:pr is:open author:dependabot[bot] sort:updated-desc"
    );
    assert_eq!(
        dependency_label_query(&repository),
        "repo:owner/repo is:pr is:open label:dependencies sort:updated-desc"
    );
}

#[test]
fn search_label_filter_admits_only_matching_labels() {
    assert!(search_label_matches_filter(
        &["bug".into(), "automation".into()],
        &["automation".into()]
    ));
    assert!(!search_label_matches_filter(
        &["docs".into()],
        &["automation".into()]
    ));
    assert!(search_label_matches_filter(
        &["bug".into()],
        &[" Bug ".into()]
    ));
    assert!(search_label_matches_filter(&["bug".into()], &[]));
}

#[tokio::test]
async fn github_inbox_pull_skips_failed_repository_and_keeps_pullable_tasks() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(
            422,
            json!({
                "message": "Validation Failed",
                "errors": [{
                    "message": "The listed users and repositories cannot be searched either \
                        because the resources do not exist or you do not have permission to view \
                        them.",
                    "resource": "Search",
                    "field": "q",
                    "code": "invalid"
                }]
            }),
        ),
        MockResponse::json(
            200,
            search_response_with_issue("https://example.test/good/7"),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["bad/repo", "good/repo"]);

    let tasks = client.pull_tasks().await.expect("partial inbox pull");

    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    // viewer + bad(assigned fails) + good(assigned, review, two dependency-bot
    // searches, dependency-labelled)
    assert_eq!(requests.len(), 7);
    assert!(requests[1].contains("repo:bad/repo"));
    assert!(requests[2].contains("repo:good/repo"));
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].reference.external_id, "good/repo#7");
    assert_eq!(tasks[0].status, TaskBoardStatus::Inbox);
}

#[tokio::test]
async fn github_inbox_pull_imports_review_requests_as_inbox() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(
            200,
            search_response_with_issue("https://example.test/good/pull/7"),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);

    let tasks = client.pull_tasks().await.expect("inbox pull");

    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    // viewer + assigned + review + two dependency-bot searches + dependency label
    assert_eq!(requests.len(), 6);
    assert!(requests[2].contains("review-requested:octo-user"));
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].status, TaskBoardStatus::Inbox);
}

#[tokio::test]
async fn github_inbox_review_request_tasks_parse_the_same_tracking_convention_as_issues() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, _requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(
            200,
            search_response_with_issue_body("https://example.test/good/pull/7", "Part of #5"),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);

    let tasks = client.pull_tasks().await.expect("inbox pull");

    handle.join().expect("mock server");
    assert_eq!(tasks.len(), 1);
    assert_eq!(
        tasks[0]
            .parent_reference
            .as_ref()
            .map(|reference| reference.external_id.as_str()),
        Some("good/repo#5")
    );
}

#[tokio::test]
async fn github_inbox_pull_maps_closed_assigned_issues_to_done() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, _requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(
            200,
            search_response_with_issue_state("https://example.test/good/7", "CLOSED"),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);

    let tasks = client.pull_tasks().await.expect("inbox pull");

    handle.join().expect("mock server");
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].status, TaskBoardStatus::Done);
}

#[tokio::test]
async fn github_inbox_discovers_dependency_update_pull_requests() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(
            200,
            search_response_with_pull_request(
                12,
                "https://example.test/good/pull/12",
                "abc123",
                "renovate[bot]",
            ),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);

    let tasks = client.pull_tasks().await.expect("inbox pull");

    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    assert!(requests[3].contains("author:renovate[bot]"));
    assert!(requests[4].contains("author:dependabot[bot]"));
    assert!(requests[5].contains("label:dependencies"));
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].workflow_kind, TaskBoardWorkflowKind::PrFix);
    assert_eq!(tasks[0].pr_head_revision.as_deref(), Some("abc123"));
    assert_eq!(tasks[0].pr_author.as_deref(), Some("renovate[bot]"));
    assert_eq!(tasks[0].status, TaskBoardStatus::Inbox);
}

#[tokio::test]
async fn github_inbox_folds_a_pull_request_with_both_intents_into_one_ticket() {
    let _guard = acquire_global_budget_test_lock().await;
    // The same pull request #7 is both review-requested and a dependency update,
    // so it must import once carrying both intents rather than twice.
    let (endpoint, _requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(
            200,
            search_response_with_pull_request(
                7,
                "https://example.test/good/pull/7",
                "deadbeef",
                "renovate[bot]",
            ),
        ),
        MockResponse::json(
            200,
            search_response_with_pull_request(
                7,
                "https://example.test/good/pull/7",
                "deadbeef",
                "renovate[bot]",
            ),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);

    let tasks = client.pull_tasks().await.expect("inbox pull");

    handle.join().expect("mock server");
    assert_eq!(tasks.len(), 1, "both intents fold into one ticket");
    assert_eq!(tasks[0].workflow_kind, TaskBoardWorkflowKind::PrFixReview);
    assert_eq!(tasks[0].pr_head_revision.as_deref(), Some("deadbeef"));
}

#[tokio::test]
async fn github_inbox_assigned_only_still_discovers_dependency_pull_requests() {
    let _guard = acquire_global_budget_test_lock().await;
    // An assigned-only client skips the review-request search yet must still
    // find the dependency-only pull request, its sole discovery source.
    let (endpoint, requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(
            200,
            search_response_with_pull_request(
                12,
                "https://example.test/good/pull/12",
                "abc123",
                "renovate[bot]",
            ),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = assigned_only_inbox_client(&endpoint, &["good/repo"]);

    let tasks = client.pull_tasks().await.expect("assigned-only inbox pull");

    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    // viewer + assigned + two dependency-bot searches + dependency label, and
    // no review-request search.
    assert_eq!(requests.len(), 5);
    assert!(
        requests
            .iter()
            .all(|request| !request.contains("review-requested"))
    );
    assert!(requests[2].contains("author:renovate[bot]"));
    assert_eq!(tasks.len(), 1);
    assert_eq!(tasks[0].workflow_kind, TaskBoardWorkflowKind::PrFix);
    assert_eq!(tasks[0].pr_head_revision.as_deref(), Some("abc123"));
    assert!(
        !client.authoritative_review_inbox(),
        "an assigned-only client never closes review tickets"
    );
}

#[tokio::test]
async fn github_inbox_incomplete_pull_drops_authoritative_review_inbox() {
    let _guard = acquire_global_budget_test_lock().await;
    // The review-request search fails while the assigned search succeeds, so
    // the pull returns partial results and must not stay authoritative: a
    // ticket whose pull request is missing only behind the failure would
    // otherwise be closed.
    let (endpoint, _requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(
            200,
            search_response_with_issue("https://example.test/good/7"),
        ),
        MockResponse::json(
            422,
            json!({
                "message": "Validation Failed",
                "errors": [{
                    "message": "review search failed",
                    "resource": "Search",
                    "field": "q",
                    "code": "invalid"
                }]
            }),
        ),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);
    assert!(
        client.authoritative_review_inbox(),
        "a review-importing client starts authoritative"
    );

    let tasks = client.pull_tasks().await.expect("partial inbox pull");

    handle.join().expect("mock server");
    assert_eq!(tasks.len(), 1);
    assert!(
        !client.authoritative_review_inbox(),
        "a pull that skipped a failed query must not act authoritative"
    );
}

#[tokio::test]
async fn github_inbox_complete_pull_keeps_authoritative_review_inbox() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, _requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
        MockResponse::json(200, empty_search_response()),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["good/repo"]);

    client.pull_tasks().await.expect("inbox pull");

    handle.join().expect("mock server");
    assert!(
        client.authoritative_review_inbox(),
        "a pull with every query succeeding stays authoritative"
    );
}

#[tokio::test]
async fn github_inbox_pull_fails_when_no_repository_can_be_pulled() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, _requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, viewer_response("octo-user")),
        MockResponse::json(
            422,
            json!({
                "message": "Validation Failed",
                "errors": [{
                    "message": "The listed users and repositories cannot be searched either \
                        because the resources do not exist or you do not have permission to view \
                        them.",
                    "resource": "Search",
                    "field": "q",
                    "code": "invalid"
                }]
            }),
        ),
    ]);
    let client = inbox_client_with_base_uri(&endpoint, &["bad/repo"]);

    let error = client
        .pull_tasks()
        .await
        .expect_err("all repositories fail");

    handle.join().expect("mock server");
    assert!(
        error
            .message()
            .contains("failed for all configured repositories")
    );
    assert!(
        error
            .details()
            .expect("details")
            .contains("bad/repo assigned issue search failed")
    );
}
