use serde_json::json;
use std::process::Command;
use std::{env, thread};
use tempfile::tempdir;
use tokio::runtime::Builder as RuntimeBuilder;

use super::super::*;
use super::support::{
    MockResponse, assigned_only_background_batched_clients, assigned_only_batched_clients,
    batched_clients_with_reviews, empty_batch_search_response, spawn_sequence_mock,
};
use crate::external::{ExternalSyncDirection, ExternalSyncOptions, sync_external_tasks_scoped};
use crate::store::TaskBoardStore;
use harness_github_api::acquire_global_budget_test_lock;

const DAEMON_STACK_CHILD_ENV: &str = "HARNESS_TEST_GITHUB_INBOX_DAEMON_STACK_CHILD";
const DAEMON_STACK_TEST: &str =
    "external::github::inbox::tests::batch::scoped_review_batch_survives_daemon_worker_stack";
// WebSocket dispatch and tracing consume the rest of the production worker's 2 MiB stack.
const INBOX_BATCH_STACK_HEADROOM: usize = 256 * 1024;

#[tokio::test]
async fn scoped_inbox_clients_share_batched_repository_reads() {
    let _guard = acquire_global_budget_test_lock().await;
    let responses = (0..2)
        .map(|_| MockResponse::json(200, empty_batch_search_response(4)))
        .collect();
    let (endpoint, requests, handle) = spawn_sequence_mock(responses);
    let clients = assigned_only_batched_clients(&endpoint, &["owner/one", "other/two"]);

    let (first, second) = tokio::join!(clients[0].pull_tasks(), clients[1].pull_tasks());

    first.expect("first batched repository");
    second.expect("second batched repository");
    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    assert_eq!(requests.len(), 2);
    assert!(requests.iter().all(|request| {
        request.contains("TaskBoardGitHubInboxBatch")
            && request.contains("$q3")
            && !request.contains("$q4")
            && request.contains("assignee:@me")
    }));
    assert!(
        requests
            .iter()
            .any(|request| request.contains("repo:owner/one"))
    );
    assert!(
        requests
            .iter()
            .any(|request| request.contains("repo:other/two"))
    );
}

#[tokio::test]
async fn scoped_review_clients_share_batched_repository_reads() {
    let _guard = acquire_global_budget_test_lock().await;
    let responses = (0..2)
        .map(|_| MockResponse::json(200, empty_batch_search_response(5)))
        .collect();
    let (endpoint, requests, handle) = spawn_sequence_mock(responses);
    let clients = batched_clients_with_reviews(&endpoint, &["owner/one", "other/two"]);

    let (first, second) = tokio::join!(clients[0].pull_tasks(), clients[1].pull_tasks());

    first.expect("first batched repository");
    second.expect("second batched repository");
    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    assert_eq!(requests.len(), 2);
    assert!(requests.iter().all(|request| {
        request.contains("$q4")
            && !request.contains("$q5")
            && request.contains("review-requested:@me")
    }));
    assert!(clients[0].authoritative_review_inbox());
}

#[tokio::test]
async fn scoped_review_batch_uses_one_gateway_safe_request_per_repository() {
    let _guard = acquire_global_budget_test_lock().await;
    let responses = (0..7)
        .map(|_| MockResponse::json(200, empty_batch_search_response(5)))
        .collect();
    let (endpoint, requests, handle) = spawn_sequence_mock(responses);
    let clients = batched_clients_with_reviews(
        &endpoint,
        &[
            "owner/one",
            "owner/two",
            "owner/three",
            "owner/four",
            "owner/five",
            "owner/six",
            "owner/seven",
        ],
    );

    clients[0].pull_tasks().await.expect("chunked batch");

    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    assert_eq!(requests.len(), 7);
    assert!(requests.iter().all(|request| {
        request.contains("$q4") && !request.contains("$q5") && request.matches("repo:").count() == 5
    }));
    assert!(
        requests
            .iter()
            .any(|request| request.contains("repo:owner/one"))
    );
    assert!(
        requests
            .iter()
            .any(|request| request.contains("repo:owner/seven"))
    );
}

#[test]
fn scoped_review_batch_survives_daemon_worker_stack() {
    if env::var_os(DAEMON_STACK_CHILD_ENV).is_none() {
        let output = Command::new(env::current_exe().expect("current test executable"))
            .args(["--exact", DAEMON_STACK_TEST, "--nocapture"])
            .env(DAEMON_STACK_CHILD_ENV, "1")
            .output()
            .expect("run isolated daemon-stack inbox test");
        assert!(
            output.status.success(),
            "isolated daemon-stack inbox test failed: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr),
        );
        return;
    }

    let worker = thread::Builder::new()
        .name("daemon-stack-inbox".into())
        .stack_size(INBOX_BATCH_STACK_HEADROOM)
        .spawn(|| {
            let runtime = RuntimeBuilder::new_current_thread()
                .enable_all()
                .build()
                .expect("current-thread runtime");
            runtime.block_on(async {
                let _guard = acquire_global_budget_test_lock().await;
                let repositories = (0..30)
                    .map(|index| format!("owner/repo-{index}"))
                    .collect::<Vec<_>>();
                let repository_refs = repositories.iter().map(String::as_str).collect::<Vec<_>>();
                let responses = (0..repositories.len())
                    .map(|_| MockResponse::json(200, empty_batch_search_response(5)))
                    .collect();
                let (endpoint, requests, handle) = spawn_sequence_mock(responses);
                let clients = batched_clients_with_reviews(&endpoint, &repository_refs)
                    .into_iter()
                    .map(|client| Box::new(client) as Box<dyn ExternalSyncClient>)
                    .collect::<Vec<_>>();
                let temp = tempdir().expect("tempdir");
                let board = TaskBoardStore::new(temp.path().join("board"));

                sync_external_tasks_scoped(
                    &board,
                    ExternalSyncOptions {
                        direction: ExternalSyncDirection::Pull,
                        ..ExternalSyncOptions::default()
                    },
                    &clients,
                )
                .await
                .expect("full inbox sync");

                handle.join().expect("mock server");
                assert_eq!(requests.lock().expect("requests").len(), repositories.len());
            });
        })
        .expect("spawn daemon-stack inbox test");
    worker.join().expect("daemon-stack inbox test");
}

#[tokio::test]
async fn scoped_batch_continues_from_the_aliased_page_cursor() {
    let _guard = acquire_global_budget_test_lock().await;
    let first_page = json!({
        "data": {
            "q0": {
                "pageInfo": { "hasNextPage": true, "endCursor": "cursor-1" },
                "nodes": []
            },
            "q1": {
                "pageInfo": { "hasNextPage": false, "endCursor": null },
                "nodes": []
            },
            "q2": {
                "pageInfo": { "hasNextPage": false, "endCursor": null },
                "nodes": []
            },
            "q3": {
                "pageInfo": { "hasNextPage": false, "endCursor": null },
                "nodes": []
            }
        }
    });
    let second_page = json!({
        "data": {
            "search": {
                "pageInfo": { "hasNextPage": false, "endCursor": null },
                "nodes": []
            }
        }
    });
    let (endpoint, requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, first_page),
        MockResponse::json(200, second_page),
    ]);
    let clients = assigned_only_background_batched_clients(&endpoint, &["owner/one"]);

    clients[0].pull_tasks().await.expect("continued batch");

    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    assert_eq!(requests.len(), 2);
    assert!(requests[0].contains("TaskBoardGitHubInboxBatch"));
    assert!(requests[0].contains("first: 100"));
    assert!(requests[0].contains("\\n      body\\n"));
    assert!(requests[1].contains("\"after\":\"cursor-1\""));
}

#[tokio::test]
async fn fresh_scoped_batch_loads_complete_history_and_bodies() {
    let _guard = acquire_global_budget_test_lock().await;
    let response = json!({
        "data": {
            "q0": {
                "pageInfo": { "hasNextPage": false, "endCursor": null },
                "nodes": []
            },
            "q1": {
                "pageInfo": { "hasNextPage": true, "endCursor": "older-reviews" },
                "nodes": []
            },
            "q2": {
                "pageInfo": { "hasNextPage": false, "endCursor": null },
                "nodes": []
            },
            "q3": {
                "pageInfo": { "hasNextPage": false, "endCursor": null },
                "nodes": []
            },
            "q4": {
                "pageInfo": { "hasNextPage": false, "endCursor": null },
                "nodes": []
            }
        }
    });
    let continued = json!({
        "data": {
            "search": {
                "pageInfo": { "hasNextPage": false, "endCursor": null },
                "nodes": []
            }
        }
    });
    let (endpoint, requests, handle) = spawn_sequence_mock(vec![
        MockResponse::json(200, response),
        MockResponse::json(200, continued),
    ]);
    let clients = batched_clients_with_reviews(&endpoint, &["owner/one"]);

    clients[0]
        .pull_tasks()
        .await
        .expect("fresh complete history");

    handle.join().expect("mock server");
    let requests = requests.lock().expect("requests");
    assert_eq!(requests.len(), 2);
    assert!(requests[0].contains("first: 100"));
    assert!(requests[0].contains("\\n      body\\n"));
    assert!(requests[1].contains("\"after\":\"older-reviews\""));
    assert!(clients[0].authoritative_review_inbox());
}
