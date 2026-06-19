use super::super::types::SearchResponse;
use super::super::types::{CheckSuiteNode, StatusContextNode};
use super::super::*;

#[test]
fn append_check_contexts_preserves_check_details_urls() {
    let check_run_url = "https://github.com/acme/api/actions/runs/1/job/2";
    let status_context_url = "https://ci.example.com/acme/api/build/1";
    let mut item = sample_review_item();

    super::super::mapping::append_check_contexts(
        &mut item,
        vec![
            StatusContextNode::CheckRun {
                name: "Analyze (go)".into(),
                status: Some("COMPLETED".into()),
                conclusion: Some("SUCCESS".into()),
                url: Some(check_run_url.into()),
                check_suite: Some(CheckSuiteNode {
                    id: Some("suite-1".into()),
                }),
            },
            StatusContextNode::StatusContext {
                context: "legacy/ci".into(),
                state: Some("SUCCESS".into()),
                target_url: Some(status_context_url.into()),
            },
        ],
        &[],
    );

    assert_eq!(item.checks.len(), 2);
    assert_eq!(item.checks[0].details_url.as_deref(), Some(check_run_url));
    assert_eq!(
        item.checks[1].details_url.as_deref(),
        Some(status_context_url)
    );
    assert_eq!(item.check_status, ReviewCheckStatus::Success);
}

#[test]
fn append_check_contexts_drops_empty_and_non_web_details_urls() {
    let mut item = sample_review_item();

    super::super::mapping::append_check_contexts(
        &mut item,
        vec![
            StatusContextNode::CheckRun {
                name: "empty".into(),
                status: Some("COMPLETED".into()),
                conclusion: Some("SUCCESS".into()),
                url: Some("   ".into()),
                check_suite: None,
            },
            StatusContextNode::StatusContext {
                context: "scripted".into(),
                state: Some("SUCCESS".into()),
                target_url: Some("javascript:alert(1)".into()),
            },
        ],
        &[],
    );

    assert_eq!(item.checks.len(), 2);
    assert!(item.checks.iter().all(|check| check.details_url.is_none()));
}

#[test]
fn graphql_payload_preserves_check_urls_into_daemon_json() {
    let check_run_url = "https://github.com/acme/api/actions/runs/42/job/99";
    let status_context_url = "https://ci.example.com/acme/api/42";
    let response: SearchResponse = serde_json::from_value(serde_json::json!({
        "search": {
            "pageInfo": {
                "hasNextPage": false,
                "endCursor": null
            },
            "nodes": [
                {
                    "id": "PR_kwDO",
                    "number": 42,
                    "title": "chore(deps): bump actions/setup-go",
                    "url": "https://github.com/acme/api/pull/42",
                    "state": "OPEN",
                    "mergeable": "MERGEABLE",
                    "isDraft": false,
                    "viewerCanMergeAsAdmin": true,
                    "reviewDecision": "REVIEW_REQUIRED",
                    "headRefOid": "abc123",
                    "author": {
                        "login": "renovate[bot]",
                        "avatarUrl": "https://avatars.githubusercontent.com/in/2740?v=4"
                    },
                    "repository": {
                        "id": "R_1",
                        "nameWithOwner": "acme/api",
                        "labels": {
                            "pageInfo": {
                                "hasNextPage": false,
                                "endCursor": null
                            },
                            "nodes": []
                        }
                    },
                    "baseRef": {
                        "branchProtectionRule": {
                            "requiredStatusCheckContexts": ["legacy/ci"],
                            "requiredStatusChecks": [{ "context": "Analyze (go)" }]
                        }
                    },
                    "commits": {
                        "nodes": [
                            {
                                "commit": {
                                    "statusCheckRollup": {
                                        "contexts": {
                                            "pageInfo": {
                                                "hasNextPage": false,
                                                "endCursor": null
                                            },
                                            "nodes": [
                                                {
                                                    "name": "Analyze (go)",
                                                    "status": "COMPLETED",
                                                    "conclusion": "SUCCESS",
                                                    "url": check_run_url,
                                                    "checkSuite": { "id": "suite-1" }
                                                },
                                                {
                                                    "context": "legacy/ci",
                                                    "state": "FAILURE",
                                                    "targetUrl": status_context_url
                                                },
                                                {
                                                    "name": "Skipped url",
                                                    "status": "COMPLETED",
                                                    "conclusion": "SUCCESS",
                                                    "url": "mailto:ci@example.com",
                                                    "checkSuite": null
                                                }
                                            ]
                                        }
                                    }
                                }
                            }
                        ]
                    },
                    "reviews": {
                        "pageInfo": {
                            "hasNextPage": false,
                            "endCursor": null
                        },
                        "nodes": [
                            {
                                "author": {
                                    "login": "renovate[bot]",
                                    "avatarUrl": "https://avatars.githubusercontent.com/in/2740?v=4"
                                },
                                "state": "APPROVED"
                            }
                        ]
                    },
                    "labels": {
                        "pageInfo": {
                            "hasNextPage": false,
                            "endCursor": null
                        },
                        "nodes": [{ "name": "dependencies" }]
                    },
                    "additions": 12,
                    "deletions": 4,
                    "createdAt": "2026-01-01T00:00:00Z",
                    "updatedAt": "2026-01-01T00:01:00Z"
                }
            ]
        }
    }))
    .expect("GraphQL fixture decodes");

    let node = response
        .search
        .nodes
        .into_iter()
        .next()
        .expect("fixture node");
    let (item, _, _) = super::super::mapping::convert_node(node, None).expect("convert node");

    assert_eq!(item.checks.len(), 3);
    assert_eq!(item.checks[0].details_url.as_deref(), Some(check_run_url));
    assert_eq!(
        item.checks[1].details_url.as_deref(),
        Some(status_context_url)
    );
    assert_eq!(item.checks[2].details_url, None);
    assert!(item.viewer_can_merge_as_admin);
    assert_eq!(
        item.author_avatar_url.as_deref(),
        Some("https://avatars.githubusercontent.com/in/2740?v=4")
    );
    assert_eq!(
        item.reviews
            .first()
            .and_then(|review| review.author_avatar_url.as_deref()),
        Some("https://avatars.githubusercontent.com/in/2740?v=4")
    );
    assert_eq!(
        item.required_failed_check_names,
        vec!["legacy/ci".to_string()]
    );

    let serialized = serde_json::to_value(&item).expect("serialize item");
    let checks = serialized["checks"].as_array().expect("checks");
    assert_eq!(checks[0]["details_url"].as_str(), Some(check_run_url));
    assert_eq!(checks[1]["details_url"].as_str(), Some(status_context_url));
    assert!(checks[2].get("details_url").is_none());
    assert_eq!(
        serialized["author_avatar_url"].as_str(),
        Some("https://avatars.githubusercontent.com/in/2740?v=4")
    );
    assert_eq!(
        serialized["viewer_can_merge_as_admin"].as_bool(),
        Some(true)
    );
}

#[test]
fn paginated_check_contexts_preserve_later_page_details_urls() {
    let first_page_url = "https://github.com/acme/api/actions/runs/1/job/2";
    let later_page_url = "https://github.com/acme/api/actions/runs/1/job/3";
    let mut item = sample_review_item();
    super::super::mapping::append_check_contexts(
        &mut item,
        vec![StatusContextNode::CheckRun {
            name: "Test".into(),
            status: Some("COMPLETED".into()),
            conclusion: Some("SUCCESS".into()),
            url: Some(first_page_url.into()),
            check_suite: Some(CheckSuiteNode {
                id: Some("suite-1".into()),
            }),
        }],
        &[],
    );

    super::super::mapping::append_check_contexts(
        &mut item,
        vec![StatusContextNode::CheckRun {
            name: "Analyze".into(),
            status: Some("COMPLETED".into()),
            conclusion: Some("SUCCESS".into()),
            url: Some(later_page_url.into()),
            check_suite: Some(CheckSuiteNode {
                id: Some("suite-2".into()),
            }),
        }],
        &[],
    );

    assert_eq!(
        item.checks
            .iter()
            .filter_map(|check| check.details_url.as_deref())
            .collect::<Vec<_>>(),
        vec![first_page_url, later_page_url]
    );
    assert_eq!(item.check_status, ReviewCheckStatus::Success);
}

#[test]
fn append_check_contexts_recomputes_required_failed_check_names() {
    let mut item = sample_review_item();
    super::super::mapping::append_check_contexts(
        &mut item,
        vec![
            StatusContextNode::CheckRun {
                name: "required/check".into(),
                status: Some("COMPLETED".into()),
                conclusion: Some("FAILURE".into()),
                url: None,
                check_suite: Some(CheckSuiteNode {
                    id: Some("suite-required".into()),
                }),
            },
            StatusContextNode::StatusContext {
                context: "optional/check".into(),
                state: Some("FAILURE".into()),
                target_url: None,
            },
        ],
        &["required/check".to_string()],
    );

    assert_eq!(
        item.required_failed_check_names,
        vec!["required/check".to_string()]
    );
}

pub(super) fn sample_review_item() -> ReviewItem {
    ReviewItem {
        pull_request_id: "pr-1".into(),
        repository_id: "repo-1".into(),
        repository: "acme/api".into(),
        number: 1,
        title: "Update dependencies".into(),
        url: "https://github.com/acme/api/pull/1".into(),
        base_ref_name: None,
        default_branch_name: None,
        author_login: "renovate[bot]".into(),
        author_avatar_url: None,
        author_association: crate::reviews::ReviewAuthorAssociation::None,
        state: ReviewPullRequestState::Open,
        mergeable: ReviewMergeableState::Mergeable,
        review_status: ReviewReviewStatus::None,
        check_status: ReviewCheckStatus::None,
        flags: crate::reviews::ReviewItemFlags {
            policy_blocked: false,
            is_draft: false,
            viewer_can_update: true,
            viewer_is_requested_reviewer: false,
        },
        viewer_can_merge_as_admin: false,
        head_sha: "abc123".into(),
        labels: Vec::new(),
        checks: Vec::new(),
        reviews: Vec::new(),
        additions: 1,
        deletions: 0,
        created_at: parse_timestamp("2026-01-01T00:00:00Z").expect("created timestamp"),
        updated_at: parse_timestamp("2026-01-01T00:01:00Z").expect("updated timestamp"),
        required_failed_check_names: Vec::new(),
    }
}
