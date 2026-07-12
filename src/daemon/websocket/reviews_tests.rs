use serde_json::{Value, json};
use tempfile::tempdir;

use super::super::test_support::test_http_state_with_db;
use super::dispatch_reviews_method;
use crate::daemon::protocol::{WsRequest, ws_methods};

#[tokio::test]
async fn review_write_websocket_routes_fail_closed_without_enforced_policy() {
    let temp = tempdir().expect("tempdir");
    let xdg_root = temp.path().join("xdg");
    let xdg_root = xdg_root.to_str().expect("utf8 xdg").to_owned();
    temp_env::async_with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg_root.as_str())),
            ("CLAUDE_SESSION_ID", Some("ws-review-policy-writes")),
        ],
        async {
            let state = test_http_state_with_db();

            for case in review_websocket_write_cases() {
                let request = WsRequest {
                    id: format!("req-{}", case.method),
                    method: case.method.to_owned(),
                    params: case.payload,
                    trace_context: None,
                };
                let response = dispatch_reviews_method(&request, &state)
                    .await
                    .expect("handled review method");
                let error = response.error.expect("policy error");
                assert_eq!(error.status_code, Some(400), "{}: {error:?}", case.method);
                assert!(
                    error.message.ends_with(case.message),
                    "{} returned unexpected policy error: {error:?}",
                    case.method
                );
            }
        },
    )
    .await;
}

struct ReviewWriteCase {
    method: &'static str,
    payload: Value,
    message: &'static str,
}

fn review_websocket_write_cases() -> Vec<ReviewWriteCase> {
    vec![
        ReviewWriteCase {
            method: ws_methods::REVIEWS_APPROVE,
            payload: json!({ "targets": [review_target()], "source": "direct" }),
            message: "reviews GitHub approve is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            method: ws_methods::REVIEWS_MERGE,
            payload: json!({ "targets": [review_target()], "method": "squash" }),
            message: "reviews GitHub merge is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            method: ws_methods::REVIEWS_RERUN_CHECKS,
            payload: json!({ "targets": [review_target()] }),
            message: "reviews GitHub rerun checks is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            method: ws_methods::REVIEWS_ADD_LABEL,
            payload: json!({ "targets": [review_target()], "label": "ready" }),
            message: "reviews GitHub add label is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            method: ws_methods::REVIEWS_REQUEST_REVIEW,
            payload: json!({ "targets": [review_target()], "reviewer_login": "reviewer" }),
            message: "reviews GitHub request review is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            method: ws_methods::REVIEWS_COMMENT,
            payload: json!({ "targets": [review_target()], "body": "@dependabot rebase" }),
            message: "reviews GitHub comment is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            method: ws_methods::REVIEWS_FILES_COMMENT,
            payload: review_file_comment(),
            message: "reviews GitHub file comment is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            method: ws_methods::REVIEWS_BODY_UPDATE,
            payload: json!({
                "pull_request_id": "PR_kwDOReview1",
                "expected_prior_body_sha256": "0".repeat(64),
                "new_body": "updated body"
            }),
            message: "reviews GitHub update body is disabled because no enforced policy canvas is active",
        },
        ReviewWriteCase {
            method: ws_methods::REVIEWS_FILES_VIEWED,
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
            method: ws_methods::REVIEWS_REVIEW_THREADS_RESOLVE,
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
