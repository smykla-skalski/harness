use std::sync::atomic::{AtomicUsize, Ordering};

use reqwest::header::{HeaderValue, LINK};
use serde_json::json;

use super::*;
use crate::github_api::{GitHubProtectedClient, acquire_global_budget_test_lock};
use crate::task_board::TaskBoardStatus;
use crate::task_board::external::ExternalSyncClient;

use super::super::test_support::{MockResponse, spawn_sequence_mock};

const KEY: &str = "123e4567-e89b-12d3-a456-426614174000";

mod post_error_tests;

#[test]
fn github_client_exposes_target_scoped_recovery_capability() {
    let configured = sync_client("http://127.0.0.1:1", Some("acme/widgets"));
    let linked = sync_client("http://127.0.0.1:1", None);
    let recovery = configured
        .external_create_recovery()
        .expect("recovery capability");

    assert_eq!(recovery.provider(), ExternalProvider::GitHub);
    assert!(recovery.supports_target("acme/widgets"));
    assert!(!recovery.supports_target("acme/other"));
    assert!(!recovery.supports_target("Acme/Widgets"));
    assert!(!recovery.supports_target(" acme/widgets "));
    assert!(
        linked
            .external_create_recovery()
            .expect("linked recovery")
            .supports_target("other/repository")
    );
}

#[tokio::test]
async fn create_started_renews_then_posts_exact_marked_body() {
    let _guard = acquire_global_budget_test_lock().await;
    let body = "Unicode 🐋 with trailing \t";
    let marked = render_body(body, KEY).expect("marker");
    let response = issue_json(17, &marked, false);
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![MockResponse::json(response)]);
    let client = sync_client(&endpoint, Some("acme/widgets"));
    let lease = TestLease::default();

    let task = recovery(&client)
        .create_started(&request(body), &lease)
        .await
        .expect("created task");

    handle.join().expect("mock server");
    assert_eq!(lease.count(), 1);
    assert_task(&task, 17, body);
    let captured = captured.lock().expect("captured");
    assert_eq!(captured.len(), 1);
    assert_eq!(captured[0].method, "POST");
    assert_eq!(captured[0].path, "/repos/acme/widgets/issues");
    let posted: serde_json::Value = serde_json::from_str(&captured[0].body).expect("posted JSON");
    assert_eq!(posted["title"], "Task title");
    assert_eq!(posted["body"], marked);
}

#[tokio::test]
async fn lease_failure_prevents_initial_post() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, captured, handle) = spawn_sequence_mock(Vec::new());
    let client = sync_client(&endpoint, Some("acme/widgets"));
    let lease = TestLease::failing_on(1);

    let error = recovery(&client)
        .create_started(&request("body"), &lease)
        .await
        .expect_err("lease failure");

    handle.join().expect("mock server");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert!(captured.lock().expect("captured").is_empty());
}

#[tokio::test]
async fn created_response_without_marker_fails_closed_after_one_post() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, captured, handle) =
        spawn_sequence_mock(vec![MockResponse::json(issue_json(16, "ordinary", false))]);
    let client = sync_client(&endpoint, Some("acme/widgets"));

    let error = recovery(&client)
        .create_started(&request("body"), &TestLease::default())
        .await
        .expect_err("missing response marker");

    handle.join().expect("mock server");
    assert_eq!(error.code(), "WORKFLOW_PARSE");
    let captured = captured.lock().expect("captured");
    assert_eq!(captured.len(), 1);
    assert_eq!(captured[0].method, "POST");
}

#[tokio::test]
async fn post_error_recovers_found_issue_with_one_exhaustive_scan() {
    let _guard = acquire_global_budget_test_lock().await;
    let marked = render_body("body", KEY).expect("marker");
    let responses = vec![
        MockResponse::status(500, r#"{"message":"post failed"}"#),
        MockResponse::json(format!("[{}]", issue_json(18, &marked, false))),
        MockResponse::json("[]"),
    ];
    let (endpoint, captured, handle) = spawn_sequence_mock(responses);
    let client = sync_client(&endpoint, Some("acme/widgets"));
    let lease = TestLease::default();

    let task = recovery(&client)
        .create_started(&request("body"), &lease)
        .await
        .expect("recovered task");

    handle.join().expect("mock server");
    assert_task(&task, 18, "body");
    assert_eq!(lease.count(), 3);
    let captured = captured.lock().expect("captured");
    assert_eq!(
        captured
            .iter()
            .filter(|request| request.method == "POST")
            .count(),
        1
    );
    assert_eq!(captured[1].path, recovery_path(1));
    assert_eq!(captured[2].path, recovery_path(2));
}

#[tokio::test]
async fn post_error_absent_returns_original_and_incomplete_adds_scan_details() {
    let _guard = acquire_global_budget_test_lock().await;
    let absent = run_failed_create(vec![
        MockResponse::status(500, r#"{"message":"post failed"}"#),
        MockResponse::json("[]"),
    ])
    .await;
    let incomplete = run_failed_create(vec![
        MockResponse::status(500, r#"{"message":"post failed"}"#),
        MockResponse::status(500, r#"{"message":"scan failed"}"#),
    ])
    .await;

    assert_eq!(absent.code(), "WORKFLOW_IO");
    assert_eq!(incomplete.code(), absent.code());
    assert_eq!(incomplete.message(), absent.message());
    let original_details = absent.details().expect("original provider details");
    assert!(
        incomplete
            .details()
            .is_some_and(|details| details.starts_with(original_details)
                && details.contains("provider recovery scan also failed"))
    );
}

#[tokio::test]
async fn recover_existing_is_get_only_and_returns_exact_found_task() {
    let _guard = acquire_global_budget_test_lock().await;
    let marked = render_body("body", KEY).expect("marker");
    let responses = vec![
        MockResponse::json(format!("[{}]", issue_json(19, &marked, false))),
        MockResponse::json("[]"),
    ];
    let (endpoint, captured, handle) = spawn_sequence_mock(responses);
    let client = sync_client(&endpoint, Some("acme/widgets"));
    let lease = TestLease::default();

    let probe = recovery(&client)
        .recover_existing(&request("body"), &lease)
        .await
        .expect("recovered");

    handle.join().expect("mock server");
    let ExternalCreateProbe::Found(task) = probe else {
        panic!("expected found task");
    };
    assert_task(&task, 19, "body");
    assert_eq!(lease.count(), 2);
    assert!(
        captured
            .lock()
            .expect("captured")
            .iter()
            .all(|request| request.method == "GET")
    );
}

#[tokio::test]
async fn recover_absent_is_blocked_without_posting() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![MockResponse::json("[]")]);
    let client = sync_client(&endpoint, Some("acme/widgets"));
    let lease = TestLease::default();

    let error = recovery(&client)
        .recover_existing(&request("body"), &lease)
        .await
        .expect_err("absent recovery must stay blocked");

    handle.join().expect("mock server");
    assert_eq!(error.code(), "WORKFLOW_IO");
    let captured = captured.lock().expect("captured");
    assert_eq!(captured.len(), 1);
    assert_eq!(captured[0].method, "GET");
}

#[tokio::test]
async fn scan_continues_after_first_match_and_rejects_a_second_issue() {
    let _guard = acquire_global_budget_test_lock().await;
    let marked = render_body("body", KEY).expect("marker");
    let responses = vec![
        MockResponse::json(format!("[{}]", issue_json(20, &marked, false))),
        MockResponse::json(format!("[{}]", issue_json(21, &marked, false))),
        MockResponse::json("[]"),
    ];
    let (endpoint, captured, handle) = spawn_sequence_mock(responses);
    let client = sync_client(&endpoint, Some("acme/widgets"));

    let error = recovery(&client)
        .recover_existing(&request("body"), &TestLease::default())
        .await
        .expect_err("duplicate marker");

    handle.join().expect("mock server");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    let captured = captured.lock().expect("captured");
    assert_eq!(captured.len(), 3);
    assert_eq!(captured[1].path, recovery_path(2));
    assert_eq!(captured[2].path, recovery_path(3));
}

#[tokio::test]
async fn repeated_raw_issue_number_is_rejected_before_pull_request_filtering() {
    let _guard = acquire_global_budget_test_lock().await;
    let marked = render_body("body", KEY).expect("marker");
    let responses = vec![
        MockResponse::json(format!("[{}]", issue_json(22, &marked, true))),
        MockResponse::json(format!("[{}]", issue_json(22, &marked, false))),
    ];
    let (endpoint, _, handle) = spawn_sequence_mock(responses);
    let client = sync_client(&endpoint, Some("acme/widgets"));

    let error = recovery(&client)
        .recover_existing(&request("body"), &TestLease::default())
        .await
        .expect_err("repeated raw issue");

    handle.join().expect("mock server");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
}

#[tokio::test]
async fn pull_request_marker_is_skipped_and_absence_stays_blocked() {
    let _guard = acquire_global_budget_test_lock().await;
    let marked = render_body("body", KEY).expect("marker");
    let responses = vec![
        MockResponse::json(format!("[{}]", issue_json(24, &marked, true))),
        MockResponse::json("[]"),
    ];
    let (endpoint, captured, handle) = spawn_sequence_mock(responses);
    let client = sync_client(&endpoint, Some("acme/widgets"));

    let error = recovery(&client)
        .recover_existing(&request("body"), &TestLease::default())
        .await
        .expect_err("pull request marker must not recover an issue");

    handle.join().expect("mock server");
    assert_eq!(error.code(), "WORKFLOW_IO");
    assert_eq!(captured.lock().expect("captured").len(), 2);
}

#[tokio::test]
async fn lease_failure_before_second_page_prevents_the_request() {
    let _guard = acquire_global_budget_test_lock().await;
    let responses = vec![MockResponse::json(format!(
        "[{}]",
        issue_json(25, "ordinary", false)
    ))];
    let (endpoint, captured, handle) = spawn_sequence_mock(responses);
    let client = sync_client(&endpoint, Some("acme/widgets"));

    let error = recovery(&client)
        .recover_existing(&request("body"), &TestLease::failing_on(2))
        .await
        .expect_err("second renewal");

    handle.join().expect("mock server");
    assert_eq!(error.code(), "WORKFLOW_CONCURRENT");
    assert_eq!(captured.lock().expect("captured").len(), 1);
}

#[tokio::test]
async fn link_target_is_consistency_evidence_not_a_followed_url() {
    let _guard = acquire_global_budget_test_lock().await;
    let next = alternate_link_url(2);
    let responses = vec![
        MockResponse::json(format!("[{}]", issue_json(23, "ordinary", false)))
            .with_header("Link", format!("<{next}>; rel=\"next\"")),
        MockResponse::json("[]"),
    ];
    let (endpoint, captured, handle) = spawn_sequence_mock(responses);
    let client = sync_client(&endpoint, Some("acme/widgets"));

    let error = recovery(&client)
        .recover_existing(&request("body"), &TestLease::default())
        .await
        .expect_err("absent remains blocked");

    handle.join().expect("mock server");
    assert_eq!(error.code(), "WORKFLOW_IO");
    let captured = captured.lock().expect("captured");
    assert_eq!(captured[1].path, recovery_path(2));
}

#[tokio::test]
async fn empty_page_with_next_link_is_incomplete() {
    let _guard = acquire_global_budget_test_lock().await;
    let response =
        MockResponse::json("[]").with_header("Link", format!("<{}>; rel=\"next\"", link_url(2)));
    let (endpoint, _, handle) = spawn_sequence_mock(vec![response]);
    let client = sync_client(&endpoint, Some("acme/widgets"));

    let error = recovery(&client)
        .recover_existing(&request("body"), &TestLease::default())
        .await
        .expect_err("empty page with next");

    handle.join().expect("mock server");
    assert_eq!(error.code(), "WORKFLOW_IO");
    assert!(error.message().contains("empty terminal page"));
}

#[test]
fn link_validation_rejects_incomplete_or_nonsequential_evidence() {
    for value in [
        "not-a-link".to_owned(),
        format!("<{}>; rel=next", link_url(2)),
        format!("<{}>; rel=\"next\"", link_url(1)),
        format!("<{}>; rel=\"next\"", link_url(3)),
        format!("<{}&page=2>; rel=\"next\"", link_url(2)),
        format!("<{}>; rel=\"next\"", link_url_with_page("02")),
        format!(
            "<{}>; rel=\"next\", <{}>; rel=\"next\"",
            link_url(2),
            link_url(2)
        ),
        format!("<{}>; rel=\"next NEXT\"", link_url(2)),
        format!("<{}>; rel=\"next\"; bad name=x", link_url(2)),
        format!("<{}>; rel=\"next\"; title=\"unterminated", link_url(2)),
    ] {
        let mut headers = HeaderMap::new();
        headers.insert(LINK, HeaderValue::from_str(&value).expect("header"));
        assert!(validate_link_headers(&headers, 1).is_err(), "{value}");
    }
    let mut invalid_utf8 = HeaderMap::new();
    invalid_utf8.insert(
        LINK,
        HeaderValue::from_bytes(b"\xff").expect("opaque header"),
    );
    assert!(validate_link_headers(&invalid_utf8, 1).is_err());
}

#[test]
fn pagination_cap_and_overflow_fail_closed() {
    let mut capped = RecoveryScanState {
        page: MAX_SCAN_PAGES,
        ..RecoveryScanState::default()
    };
    assert!(capped.advance(None).is_err());
    assert!(
        validate_link_headers(&HeaderMap::new(), u32::MAX).is_ok(),
        "no Link does not claim a next page"
    );
    capped.page = u32::MAX;
    assert!(capped.advance(None).is_err());
    let mut repeated = RecoveryScanState::default();
    repeated.visit_page().expect("first visit");
    assert!(repeated.visit_page().is_err());
}

async fn run_failed_create(responses: Vec<MockResponse>) -> CliError {
    let (endpoint, _, handle) = spawn_sequence_mock(responses);
    let client = sync_client(&endpoint, Some("acme/widgets"));
    let error = recovery(&client)
        .create_started(&request("body"), &TestLease::default())
        .await
        .expect_err("failed create");
    handle.join().expect("mock server");
    error
}

fn sync_client(endpoint: &str, repository: Option<&str>) -> GitHubSyncClient {
    GitHubSyncClient {
        client: GitHubProtectedClient::with_base_url("token", endpoint).expect("client"),
        repository: repository.map(|value| parse_github_repository(value).expect("repository")),
        pull_enabled: false,
        import_labels: Vec::new(),
    }
}

fn recovery(client: &GitHubSyncClient) -> &dyn ExternalCreateRecoveryClient {
    client
        .external_create_recovery()
        .expect("recovery capability")
}

fn request(body: &str) -> ExternalCreateRequest {
    ExternalCreateRequest::new("task-1", KEY, "Task title", body, "acme/widgets")
}

fn issue_json(number: u64, body: &str, pull_request: bool) -> String {
    let mut issue = json!({
        "number": number,
        "html_url": format!("https://example.test/acme/widgets/issues/{number}"),
        "title": "Task title",
        "body": body,
        "state": "open",
        "updated_at": "revision-1",
    });
    if pull_request {
        issue["pull_request"] = json!({ "url": "https://example.test/pulls/1" });
    }
    issue.to_string()
}

fn assert_task(task: &ExternalTask, number: u64, body: &str) {
    assert_eq!(task.reference.external_id, format!("acme/widgets#{number}"));
    assert_eq!(
        task.reference.url.as_deref(),
        Some(format!("https://example.test/acme/widgets/issues/{number}").as_str())
    );
    assert_eq!(task.title, "Task title");
    assert_eq!(task.body, body);
    assert_eq!(task.status, TaskBoardStatus::Backlog);
    assert_eq!(task.project_id.as_deref(), Some("acme/widgets"));
    assert_eq!(task.updated_at.as_deref(), Some("revision-1"));
}

fn recovery_path(page: u32) -> String {
    format!(
        "/repos/acme/widgets/issues?filter=all&state=all&sort=created&direction=asc&per_page=100&page={page}"
    )
}

fn link_url(page: u32) -> String {
    link_url_with_page(&page.to_string())
}

fn link_url_with_page(page: &str) -> String {
    format!(
        "https://evidence.test/repos/acme/widgets/issues?filter=all&state=all&sort=created&direction=asc&per_page=100&page={page}"
    )
}

fn alternate_link_url(page: u32) -> String {
    format!("https://evidence.test/repositories/42/issues?cursor=opaque&page={page}")
}

#[derive(Default)]
struct TestLease {
    renewals: AtomicUsize,
    fail_on: Option<usize>,
}

impl TestLease {
    fn failing_on(call: usize) -> Self {
        Self {
            renewals: AtomicUsize::new(0),
            fail_on: Some(call),
        }
    }

    fn count(&self) -> usize {
        self.renewals.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl ExternalCreateLease for TestLease {
    async fn renew(&self) -> Result<(), CliError> {
        let call = self.renewals.fetch_add(1, Ordering::SeqCst) + 1;
        if self.fail_on == Some(call) {
            return Err(CliErrorKind::concurrent_modification("test lease was replaced").into());
        }
        Ok(())
    }
}
