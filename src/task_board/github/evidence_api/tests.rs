use std::collections::BTreeMap;

use serde_json::json;

use super::*;

#[test]
fn required_check_names_merge_branch_protection_and_rulesets() {
    let status_checks = GitHubRequiredStatusChecksResponse {
        contexts: vec!["ci/status".to_string()],
        checks: vec![GitHubRequiredCheckResponse {
            context: "lint".to_string(),
        }],
    };
    let rules = vec![GitHubBranchRuleResponse {
        rule_type: "required_status_checks".to_string(),
        parameters: Some(GitHubBranchRuleParameters {
            required_status_checks: vec![
                GitHubRuleStatusCheck {
                    context: "test".to_string(),
                },
                GitHubRuleStatusCheck {
                    context: "lint".to_string(),
                },
            ],
        }),
    }];

    assert_eq!(
        required_check_names(Some(&status_checks), &rules),
        vec!["ci/status", "lint", "test"]
    );
}

#[test]
fn check_run_response_maps_native_check_conclusions() {
    let evidence = GitHubCheckRunResponse {
        name: "build".to_string(),
        status: "completed".to_string(),
        conclusion: Some("neutral".to_string()),
    }
    .into_evidence();

    assert_eq!(evidence.name, "build");
    assert_eq!(evidence.status, GitHubCheckStatus::Completed);
    assert_eq!(evidence.conclusion, Some(GitHubCheckConclusion::Neutral));
    assert!(evidence.is_green());
}

#[test]
fn review_rollup_uses_unresolved_review_thread_counts() {
    let mut unresolved = BTreeMap::new();
    unresolved.insert("alice".to_string(), 2);
    let reviews = vec![
        GitHubReviewRollup {
            reviewer: "alice".to_string(),
            state: GitHubReviewState::Approved,
        },
        GitHubReviewRollup {
            reviewer: "bob".to_string(),
            state: GitHubReviewState::ChangesRequested,
        },
    ];

    let evidence = merge_review_rollups(reviews, &unresolved);

    assert_eq!(evidence[0].reviewer, "alice");
    assert_eq!(evidence[0].unresolved_requested_changes, 2);
    assert_eq!(evidence[1].reviewer, "bob");
    assert_eq!(evidence[1].unresolved_requested_changes, 1);
}

#[test]
fn graphql_review_threads_count_only_unresolved_threads() {
    let response: GitHubReviewThreadsResponse = serde_json::from_value(json!({
        "repository": {
            "pullRequest": {
                "reviewThreads": {
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
                }
            }
        }
    }))
    .expect("graphql response");
    let threads = response
        .repository
        .and_then(|repository| repository.pull_request)
        .expect("pull request")
        .review_threads
        .nodes;
    let mut summary = GitHubReviewThreadSummary::default();

    summary.add_threads(threads);

    assert_eq!(summary.unresolved_by_reviewer.get("alice"), Some(&1));
    assert_eq!(summary.unresolved_by_reviewer.get("bob"), None);
}
