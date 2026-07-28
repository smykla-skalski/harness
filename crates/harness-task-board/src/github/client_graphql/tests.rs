use serde_json::json;

use super::PullRequestHandleResponse;

#[test]
fn legacy_cached_pull_request_without_state_decodes_fail_closed() {
    let response: PullRequestHandleResponse = serde_json::from_value(json!({
        "repository": {
            "pullRequest": {
                "number": 42,
                "url": "https://github.com/example/repo/pull/42",
                "isDraft": false,
                "merged": false,
                "headRefOid": "head-42",
                "headRefName": "feature/legacy-cache",
                "headRepository": { "nameWithOwner": "example/repo" },
                "reviewRequests": {
                    "pageInfo": { "hasNextPage": false, "endCursor": null },
                    "nodes": []
                }
            }
        }
    }))
    .expect("legacy cached GraphQL body");

    let handle = response.pull_request().expect("pull request").into_handle();

    assert!(!handle.open);
}

#[test]
fn unknown_graphql_pull_request_state_fails_closed() {
    let response: PullRequestHandleResponse = serde_json::from_value(json!({
        "repository": {
            "pullRequest": {
                "number": 42,
                "url": "https://github.com/example/repo/pull/42",
                "isDraft": true,
                "state": "FUTURE_STATE",
                "merged": false,
                "headRefOid": "head-42",
                "headRefName": "feature/unknown-state",
                "headRepository": { "nameWithOwner": "example/repo" },
                "reviewRequests": {
                    "pageInfo": { "hasNextPage": false, "endCursor": null },
                    "nodes": []
                }
            }
        }
    }))
    .expect("unknown GraphQL state");

    let handle = response.pull_request().expect("pull request").into_handle();

    assert!(!handle.open);
}
