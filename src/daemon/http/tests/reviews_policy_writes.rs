use reqwest::StatusCode;
use serde_json::{Value, json};
use tempfile::tempdir;

use crate::daemon::protocol::http_paths;
use crate::task_board::policy_graph::store_gate_policy;
use crate::task_board::store::default_board_root;

use super::support::test_http_state_with_db;
use super::task_board_route_parity_support::serve_http;

#[tokio::test]
async fn review_write_http_routes_fail_closed_without_enforced_policy() {
    let temp = tempdir().expect("tempdir");
    let xdg_root = temp.path().join("xdg");
    let xdg_root = xdg_root.to_str().expect("utf8 xdg").to_owned();
    temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg_root.as_str())),
            ("CLAUDE_SESSION_ID", Some("http-review-policy-writes")),
        ],
        async {
            store_gate_policy(&default_board_root(), None);
            let (base_url, server) = serve_http(test_http_state_with_db()).await;
            let client = reqwest::Client::new();

            for case in review_http_write_cases() {
                let (status, body) =
                    post_json_with_status(&client, &base_url, case.path, case.payload).await;
                assert_eq!(status, StatusCode::BAD_REQUEST, "{}: {body}", case.path);
                assert_policy_disabled_message(&body, case.message, case.path);
            }

            server.abort();
            let _ = server.await;
        },
    )
    .await;
}

fn assert_policy_disabled_message(body: &Value, expected: &str, route: &str) {
    let message = body["error"]["message"].as_str().expect("error message");
    assert!(
        message.ends_with(expected),
        "{route} returned unexpected policy error: {body}"
    );
}

async fn post_json_with_status(
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

struct ReviewWriteCase {
    path: &'static str,
    payload: Value,
    message: &'static str,
}

fn review_http_write_cases() -> Vec<ReviewWriteCase> {
    vec![
        ReviewWriteCase {
            path: http_paths::REVIEWS_APPROVE,
            payload: json!({ "targets": [review_target()] }),
            message: "reviews GitHub approve is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            path: http_paths::REVIEWS_MERGE,
            payload: json!({ "targets": [review_target()], "method": "squash" }),
            message: "reviews GitHub merge is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            path: http_paths::REVIEWS_RERUN_CHECKS,
            payload: json!({ "targets": [review_target()] }),
            message: "reviews GitHub rerun checks is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            path: http_paths::REVIEWS_LABELS,
            payload: json!({ "targets": [review_target()], "label": "ready" }),
            message: "reviews GitHub add label is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            path: http_paths::REVIEWS_REQUEST_REVIEW,
            payload: json!({ "targets": [review_target()], "reviewer_login": "reviewer" }),
            message: "reviews GitHub request review is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            path: http_paths::REVIEWS_COMMENT,
            payload: json!({ "targets": [review_target()], "body": "@dependabot rebase" }),
            message: "reviews GitHub comment is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            path: http_paths::REVIEWS_FILES_COMMENT,
            payload: review_file_comment(),
            message: "reviews GitHub file comment is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            path: http_paths::REVIEWS_BODY_UPDATE,
            payload: json!({
                "pull_request_id": "PR_kwDOReview1",
                "expected_prior_body_sha256": "0".repeat(64),
                "new_body": "updated body"
            }),
            message: "reviews GitHub update body is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            path: http_paths::REVIEWS_FILES_VIEWED,
            payload: json!({
                "pull_request_id": "PR_kwDOReview1",
                "paths": [{
                    "path": "src/lib.rs",
                    "expected_prior_state": "unviewed",
                    "mark_viewed": true
                }]
            }),
            message: "reviews GitHub update file viewed state is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            path: http_paths::REVIEWS_REVIEW_THREADS_RESOLVE,
            payload: json!({
                "thread_id": "PRRT_kwDOReviewThread1",
                "resolved": true,
                "pull_request_id": "PR_kwDOReview1"
            }),
            message: "reviews GitHub resolve review thread is disabled because no enforced policy canvas is active",
        },
    ]
}

fn review_target() -> Value {
    json!({
        "pull_request_id": "PR_kwDOReview1",
        "repository_id": "R_kwDORepo1",
        "repository": "Kong/example",
        "number": 9838,
        "url": "https://github.com/Kong/example/pull/9838",
        "state": "open",
        "head_sha": "abc123",
        "mergeable": "mergeable",
        "review_status": "review_required",
        "check_status": "success",
        "is_draft": false,
        "policy_blocked": false,
        "viewer_can_update": true,
        "viewer_can_merge_as_admin": false,
        "required_failed_check_names": [],
        "check_suite_ids": ["suite-1"]
    })
}

fn review_file_comment() -> Value {
    json!({
        "pull_request_id": "PR_kwDOReview1",
        "repository": "Kong/example",
        "kind": "new_thread",
        "body": "Please fix this before merge.",
        "path": "src/lib.rs",
        "line": 12,
        "side": "RIGHT"
    })
}
