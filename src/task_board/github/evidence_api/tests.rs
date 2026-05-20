use std::collections::BTreeMap;

use serde_json::json;

use crate::task_board::github::{GitHubCheckConclusion, GitHubCheckStatus};

use super::*;

#[test]
fn required_check_names_merge_branch_protection_contexts() {
    let rule = GraphqlBranchProtectionRule {
        required_status_check_contexts: vec!["ci/status".to_string(), "lint".to_string()],
        required_status_checks: vec![
            GraphqlRequiredStatusCheck {
                context: "test".to_string(),
            },
            GraphqlRequiredStatusCheck {
                context: "lint".to_string(),
            },
        ],
    };

    assert_eq!(
        required_check_names(&rule),
        vec!["ci/status", "lint", "test"]
    );
}

#[test]
fn check_run_context_maps_graphql_conclusions() {
    let evidence = GraphqlStatusCheckContext::CheckRun {
        name: "build".to_string(),
        status: "COMPLETED".to_string(),
        conclusion: Some("NEUTRAL".to_string()),
    }
    .evidence()
    .expect("check evidence");

    assert_eq!(evidence.name, "build");
    assert_eq!(evidence.status, GitHubCheckStatus::Completed);
    assert_eq!(evidence.conclusion, Some(GitHubCheckConclusion::Neutral));
    assert!(evidence.is_green());
}

#[test]
fn review_rollup_uses_latest_reviewer_state_and_thread_counts() {
    let mut unresolved = BTreeMap::new();
    unresolved.insert("alice".to_string(), 2);
    let reviews = vec![
        GitHubReviewRollup {
            reviewer: "alice".to_string(),
            state: GitHubReviewState::ChangesRequested,
            submitted_at: "2026-05-18T00:00:00Z".to_string(),
        },
        GitHubReviewRollup {
            reviewer: "alice".to_string(),
            state: GitHubReviewState::Approved,
            submitted_at: "2026-05-19T00:00:00Z".to_string(),
        },
        GitHubReviewRollup {
            reviewer: "bob".to_string(),
            state: GitHubReviewState::ChangesRequested,
            submitted_at: "2026-05-19T01:00:00Z".to_string(),
        },
    ];

    let evidence = merge_review_rollups(reviews, &unresolved);

    assert_eq!(evidence[0].reviewer, "alice");
    assert_eq!(evidence[0].state, GitHubReviewState::Approved);
    assert_eq!(evidence[0].unresolved_requested_changes, 2);
    assert_eq!(evidence[1].reviewer, "bob");
    assert_eq!(evidence[1].unresolved_requested_changes, 1);
}

#[test]
fn graphql_review_threads_count_only_unresolved_threads() {
    let threads: GitHubGraphqlConnection<GitHubReviewThreadNode> = serde_json::from_value(json!({
        "pageInfo": {
            "hasNextPage": false,
            "endCursor": null
        },
        "nodes": [
            {
                "isResolved": false,
                "comments": {
                    "nodes": [
                        {
                            "author": {
                                "login": "alice"
                            }
                        }
                    ]
                }
            },
            {
                "isResolved": true,
                "comments": {
                    "nodes": [
                        {
                            "author": {
                                "login": "bob"
                            }
                        }
                    ]
                }
            }
        ]
    }))
    .expect("graphql response");
    let mut summary = GitHubReviewThreadSummary::default();

    summary.add_threads(threads.nodes);

    assert_eq!(summary.unresolved_by_reviewer.get("alice"), Some(&1));
    assert_eq!(summary.unresolved_by_reviewer.get("bob"), None);
}

#[test]
fn pull_request_evidence_response_reads_only_needed_fields() {
    let response: PullRequestMergeEvidenceResponse = serde_json::from_value(json!({
        "repository": {
            "pullRequest": {
                "number": 42,
                "url": "https://github.invalid/owner/repo/pull/42",
                "isDraft": false,
                "baseRefName": "main",
                "headRefName": "feature",
                "headRefOid": "deadbeef",
                "mergeable": "MERGEABLE",
                "mergeStateStatus": "CLEAN",
                "files": {
                    "pageInfo": {
                        "hasNextPage": false,
                        "endCursor": null
                    },
                    "nodes": [
                        {
                            "path": "src/task_board/github/client.rs"
                        }
                    ]
                },
                "reviews": {
                    "pageInfo": {
                        "hasNextPage": false,
                        "endCursor": null
                    },
                    "nodes": []
                },
                "reviewThreads": {
                    "pageInfo": {
                        "hasNextPage": false,
                        "endCursor": null
                    },
                    "nodes": []
                },
                "commits": {
                    "nodes": [
                        {
                            "commit": {
                                "status": null,
                                "statusCheckRollup": null
                            }
                        }
                    ]
                },
                "baseRef": {
                    "branchProtectionRule": {
                        "requiredStatusCheckContexts": ["ci/status"],
                        "requiredStatusChecks": []
                    }
                }
            }
        }
    }))
    .expect("graphql response");
    let pull_request = response.pull_request().expect("pull request");

    assert_eq!(pull_request.number, 42);
    assert_eq!(
        pull_request.files.nodes[0].path,
        "src/task_board/github/client.rs"
    );
    assert!(pull_request_merge_allowed(&pull_request));
}
