//! Fixture-driven validation of GitHub task-board discovery.
//!
//! Discovery fans a repository out across three issue searches - work assigned
//! to the viewer, issues the viewer authored, and automation issues opened by
//! `renovate[bot]` - paginates each, and folds the results into a `BTreeMap`
//! keyed by issue number. These tests pin that contract against a local mock so
//! category overlaps, pagination, missing metadata, and provider failures
//! reproduce without touching live GitHub state.

use serde_json::{Value, json};

use super::test_support::{MockResponse, spawn_sequence_mock};
use super::*;
use harness_github_api::acquire_global_budget_test_lock;

const REPOSITORY: &str = "octocat/harness";

fn discovery_client(endpoint: &str) -> GitHubSyncClient {
    GitHubSyncClient {
        client: GitHubProtectedClient::with_base_url("token", endpoint).expect("client"),
        repository: Some(parse_github_repository(REPOSITORY).expect("repository")),
        pull_enabled: true,
        import_labels: Vec::new(),
    }
}

fn viewer(login: &str) -> MockResponse {
    MockResponse::json(json!({ "data": { "viewer": { "login": login } } }).to_string())
}

fn search_page(nodes: Vec<Value>, next_cursor: Option<&str>) -> MockResponse {
    MockResponse::json(
        json!({
            "data": {
                "search": {
                    "pageInfo": {
                        "hasNextPage": next_cursor.is_some(),
                        "endCursor": next_cursor,
                    },
                    "nodes": nodes,
                }
            }
        })
        .to_string(),
    )
}

fn empty_page() -> MockResponse {
    search_page(Vec::new(), None)
}

fn node(number: u64, title: &str) -> Value {
    full_node(number, title, Some("Body"), &["automation"])
}

fn full_node(number: u64, title: &str, body: Option<&str>, labels: &[&str]) -> Value {
    json!({
        "number": number,
        "title": title,
        "body": body,
        "url": format!("https://example.test/{REPOSITORY}/issues/{number}"),
        "state": "OPEN",
        "updatedAt": "2026-05-19T00:00:00Z",
        "labels": {
            "nodes": labels.iter().map(|name| json!({ "name": name })).collect::<Vec<_>>(),
        },
    })
}

fn external_ids(tasks: &[ExternalTask]) -> Vec<String> {
    tasks
        .iter()
        .map(|task| task.reference.external_id.clone())
        .collect()
}

#[tokio::test]
async fn discovery_pull_is_network_free_and_covers_every_intent() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![
        viewer("octo-user"),
        search_page(vec![node(10, "Assigned")], None),
        search_page(vec![node(11, "Authored")], None),
        search_page(vec![node(12, "Bump serde")], None),
    ]);

    let tasks = discovery_client(&endpoint)
        .pull_tasks()
        .await
        .expect("discovery pull");

    handle.join().expect("mock server");
    assert_eq!(
        external_ids(&tasks),
        vec![
            "octocat/harness#10",
            "octocat/harness#11",
            "octocat/harness#12"
        ]
    );
    let captured = captured.lock().expect("captured");
    assert_eq!(captured.len(), 4);
    assert!(captured[1].body.contains("assignee:octo-user"));
    assert!(captured[2].body.contains("author:octo-user"));
    assert!(captured[3].body.contains("author:renovate[bot]"));
}

#[tokio::test]
async fn discovery_dedups_a_ticket_that_matches_two_intents() {
    let _guard = acquire_global_budget_test_lock().await;
    // #7 is both assigned to the viewer and opened by renovate: two intents, one
    // ticket. The number-keyed fold must import it once, never twice.
    let (endpoint, _captured, handle) = spawn_sequence_mock(vec![
        viewer("octo-user"),
        search_page(vec![node(7, "Shared")], None),
        empty_page(),
        search_page(vec![node(7, "Shared")], None),
    ]);

    let tasks = discovery_client(&endpoint)
        .pull_tasks()
        .await
        .expect("discovery pull");

    handle.join().expect("mock server");
    assert_eq!(external_ids(&tasks), vec!["octocat/harness#7"]);
}

#[tokio::test]
async fn discovery_pagination_keeps_every_hit_exactly_once() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, captured, handle) = spawn_sequence_mock(vec![
        viewer("octo-user"),
        search_page(vec![node(1, "a"), node(2, "b")], Some("CURSOR-1")),
        search_page(vec![node(3, "c")], None),
        empty_page(),
        empty_page(),
    ]);

    let tasks = discovery_client(&endpoint)
        .pull_tasks()
        .await
        .expect("discovery pull");

    handle.join().expect("mock server");
    assert_eq!(
        external_ids(&tasks),
        vec!["octocat/harness#1", "octocat/harness#2", "octocat/harness#3"]
    );
    let captured = captured.lock().expect("captured");
    // The second page must forward the first page's cursor, or a hit is skipped.
    assert!(captured[2].body.contains("CURSOR-1"));
}

#[tokio::test]
async fn discovery_missing_optional_metadata_maps_to_a_documented_leaf() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, _captured, handle) = spawn_sequence_mock(vec![
        viewer("octo-user"),
        search_page(vec![full_node(42, "No metadata", None, &[])], None),
        empty_page(),
        empty_page(),
    ]);

    let tasks = discovery_client(&endpoint)
        .pull_tasks()
        .await
        .expect("discovery pull");

    handle.join().expect("mock server");
    assert_eq!(tasks.len(), 1);
    let task = &tasks[0];
    assert_eq!(task.body, "");
    assert!(task.labels.is_empty());
    assert!(task.parent_reference.is_none());
    assert!(!task.tracks_children);
    assert_eq!(task.status, TaskBoardStatus::Inbox);
}

#[tokio::test]
async fn discovery_empty_result_is_an_ok_empty_list() {
    let _guard = acquire_global_budget_test_lock().await;
    let (endpoint, _captured, handle) = spawn_sequence_mock(vec![
        viewer("octo-user"),
        empty_page(),
        empty_page(),
        empty_page(),
    ]);

    let tasks = discovery_client(&endpoint)
        .pull_tasks()
        .await
        .expect("empty discovery");

    handle.join().expect("mock server");
    assert!(tasks.is_empty());
}

#[tokio::test]
async fn discovery_provider_failure_is_distinct_from_an_empty_result() {
    let _guard = acquire_global_budget_test_lock().await;
    // The first intent search fails at the provider. Discovery surfaces an error
    // rather than an empty list, so an outage never reads as "no work".
    let (endpoint, _captured, handle) = spawn_sequence_mock(vec![
        viewer("octo-user"),
        MockResponse::status(500, r#"{"message":"boom"}"#),
    ]);

    let error = discovery_client(&endpoint)
        .pull_tasks()
        .await
        .expect_err("provider failure");

    handle.join().expect("mock server");
    assert!(!error.message().is_empty());
}
