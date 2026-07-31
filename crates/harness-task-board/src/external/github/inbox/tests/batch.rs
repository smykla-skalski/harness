use serde_json::json;

use super::super::*;
use super::support::{
    MockResponse, assigned_only_background_batched_clients, assigned_only_batched_clients,
    batched_clients_with_reviews, empty_batch_search_response, spawn_sequence_mock,
};
use harness_github_api::acquire_global_budget_test_lock;

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
