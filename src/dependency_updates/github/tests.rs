use super::types::PageInfo;
use super::types::RepositoryLabelNode;
use super::types::SearchResponse;
use super::types::{CheckSuiteNode, StatusContextNode};
use super::*;
use crate::dependency_updates::DependencyUpdateRepositoryLabel;

#[test]
fn scope_query_cap_rejects_broad_cartesian_requests() {
    let request = DependencyUpdatesQueryRequest {
        authors: (0..6).map(|index| format!("author-{index}")).collect(),
        organizations: (0..6).map(|index| format!("org-{index}")).collect(),
        repositories: (0..3).map(|index| format!("acme/repo-{index}")).collect(),
        exclude_repositories: Vec::new(),
        force_refresh: false,
        cache_max_age_seconds: 600,
    };

    assert!(scopes(&request).is_err());
}

#[test]
fn scopes_keep_dependency_update_searches_author_scoped() {
    let request = DependencyUpdatesQueryRequest {
        authors: vec!["renovate[bot]".into(), "octo-user".into()],
        organizations: vec!["acme".into()],
        repositories: vec!["acme/api".into()],
        exclude_repositories: Vec::new(),
        force_refresh: false,
        cache_max_age_seconds: 600,
    };
    let queries = scopes(&request)
        .expect("scopes")
        .into_iter()
        .map(|scope| scope.query)
        .collect::<Vec<_>>();

    assert_eq!(
        queries,
        vec![
            "org:acme author:octo-user is:pr is:open",
            "repo:acme/api author:octo-user is:pr is:open",
            "org:acme author:renovate[bot] is:pr is:open",
            "repo:acme/api author:renovate[bot] is:pr is:open",
        ]
    );
}

#[test]
fn page_limit_requires_narrower_dependency_update_scope() {
    let page_info = PageInfo {
        has_next_page: true,
        end_cursor: Some("cursor".to_string()),
    };

    let error = next_cursor_or_scope_limit(&page_info, SEARCH_PAGE_CAP, SEARCH_PAGE_CAP, "scope")
        .expect_err("scope limit");

    assert!(error.message().contains("narrow the request"));
}

#[test]
fn repository_label_node_decodes_color_from_github_payload() {
    let payload = serde_json::json!({
        "name": "kind/bug",
        "color": "d73a4a",
        "description": "Something isn't working"
    });
    let node: RepositoryLabelNode =
        serde_json::from_value(payload).expect("RepositoryLabelNode decodes from GitHub payload");
    assert_eq!(node.name, "kind/bug");
    assert_eq!(node.color.as_deref(), Some("d73a4a"));
    assert_eq!(node.description.as_deref(), Some("Something isn't working"));
}

#[test]
fn append_repository_labels_preserves_color_into_response_struct() {
    let mut bundle: Vec<DependencyUpdateRepositoryLabel> = Vec::new();
    super::mapping::append_repository_labels(
        &mut bundle,
        vec![
            RepositoryLabelNode {
                name: "kind/bug".into(),
                color: Some("d73a4a".into()),
                description: Some("buggy".into()),
            },
            RepositoryLabelNode {
                name: "release".into(),
                color: Some("0e8a16".into()),
                description: None,
            },
            RepositoryLabelNode {
                name: "no-color".into(),
                color: Some(String::new()),
                description: None,
            },
        ],
    );

    assert_eq!(bundle.len(), 3);
    assert_eq!(bundle[0].name, "kind/bug");
    assert_eq!(bundle[0].color.as_deref(), Some("d73a4a"));
    assert_eq!(bundle[1].color.as_deref(), Some("0e8a16"));
    assert!(
        bundle[2].color.is_none(),
        "empty color string should normalize to None"
    );

    let serialized = serde_json::to_string(&bundle).expect("serialize");
    assert!(
        serialized.contains("\"color\":\"d73a4a\""),
        "serialized JSON should keep color field: {serialized}"
    );
}

#[test]
fn append_check_contexts_preserves_check_details_urls() {
    let check_run_url = "https://github.com/acme/api/actions/runs/1/job/2";
    let status_context_url = "https://ci.example.com/acme/api/build/1";
    let mut item = sample_dependency_update_item();

    super::mapping::append_check_contexts(
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
    );

    assert_eq!(item.checks.len(), 2);
    assert_eq!(item.checks[0].details_url.as_deref(), Some(check_run_url));
    assert_eq!(
        item.checks[1].details_url.as_deref(),
        Some(status_context_url)
    );
    assert_eq!(item.check_status, DependencyUpdateCheckStatus::Success);
}

#[test]
fn append_check_contexts_drops_empty_and_non_web_details_urls() {
    let mut item = sample_dependency_update_item();

    super::mapping::append_check_contexts(
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
                    "reviewDecision": "REVIEW_REQUIRED",
                    "headRefOid": "abc123",
                    "author": { "login": "renovate[bot]" },
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
                                                    "state": "SUCCESS",
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
                        "nodes": []
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
    let (item, _, _) = super::mapping::convert_node(node).expect("convert node");

    assert_eq!(item.checks.len(), 3);
    assert_eq!(item.checks[0].details_url.as_deref(), Some(check_run_url));
    assert_eq!(
        item.checks[1].details_url.as_deref(),
        Some(status_context_url)
    );
    assert_eq!(item.checks[2].details_url, None);

    let serialized = serde_json::to_value(&item).expect("serialize item");
    let checks = serialized["checks"].as_array().expect("checks");
    assert_eq!(checks[0]["details_url"].as_str(), Some(check_run_url));
    assert_eq!(checks[1]["details_url"].as_str(), Some(status_context_url));
    assert!(checks[2].get("details_url").is_none());
}

#[test]
fn paginated_check_contexts_preserve_later_page_details_urls() {
    let first_page_url = "https://github.com/acme/api/actions/runs/1/job/2";
    let later_page_url = "https://github.com/acme/api/actions/runs/1/job/3";
    let mut item = sample_dependency_update_item();
    super::mapping::append_check_contexts(
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
    );

    super::mapping::append_check_contexts(
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
    );

    assert_eq!(
        item.checks
            .iter()
            .filter_map(|check| check.details_url.as_deref())
            .collect::<Vec<_>>(),
        vec![first_page_url, later_page_url]
    );
    assert_eq!(item.check_status, DependencyUpdateCheckStatus::Success);
}

#[test]
fn page_limit_requires_cursor_for_continuation() {
    let page_info = PageInfo {
        has_next_page: true,
        end_cursor: None,
    };

    let error =
        next_cursor_or_scope_limit(&page_info, 1, SEARCH_PAGE_CAP, "scope").expect_err("cursor");

    assert!(error.message().contains("without a cursor"));
}

fn sample_dependency_update_item() -> DependencyUpdateItem {
    DependencyUpdateItem {
        pull_request_id: "pr-1".into(),
        repository_id: "repo-1".into(),
        repository: "acme/api".into(),
        number: 1,
        title: "Update dependencies".into(),
        url: "https://github.com/acme/api/pull/1".into(),
        author_login: "renovate[bot]".into(),
        state: DependencyUpdatePullRequestState::Open,
        mergeable: DependencyUpdateMergeableState::Mergeable,
        review_status: DependencyUpdateReviewStatus::None,
        check_status: DependencyUpdateCheckStatus::None,
        policy_blocked: false,
        is_draft: false,
        head_sha: "abc123".into(),
        labels: Vec::new(),
        checks: Vec::new(),
        reviews: Vec::new(),
        additions: 1,
        deletions: 0,
        created_at: parse_timestamp("2026-01-01T00:00:00Z").expect("created timestamp"),
        updated_at: parse_timestamp("2026-01-01T00:01:00Z").expect("updated timestamp"),
        viewer_can_update: true,
    }
}

#[test]
fn production_github_timeouts_match_documented_ceilings() {
    assert_eq!(GITHUB_HTTP_CONNECT_TIMEOUT, std::time::Duration::from_secs(30));
    assert_eq!(GITHUB_HTTP_READ_TIMEOUT, std::time::Duration::from_secs(60));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn read_timeout_fires_when_github_holds_the_connection_open() {
    use std::time::{Duration, Instant};
    use octocrab::service::middleware::retry::RetryConfig;
    use tokio::net::TcpListener;

    ensure_rustls_provider();

    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let port = listener.local_addr().expect("local_addr").port();
    let accept_handle = tokio::spawn(async move {
        let mut held = Vec::new();
        loop {
            match listener.accept().await {
                Ok((stream, _)) => held.push(stream),
                Err(_) => break,
            }
        }
        held
    });

    let client = Octocrab::builder()
        .base_uri(format!("http://127.0.0.1:{port}"))
        .expect("base_uri")
        .personal_token("test-token".to_string())
        .add_retry_config(RetryConfig::None)
        .set_connect_timeout(Some(Duration::from_secs(5)))
        .set_read_timeout(Some(Duration::from_secs(2)))
        .build()
        .expect("octocrab build");

    let started = Instant::now();
    let outcome = tokio::time::timeout(
        Duration::from_secs(8),
        client.repos("octocat", "Hello-World").get(),
    )
    .await;
    let elapsed = started.elapsed();

    accept_handle.abort();

    let inner = outcome.expect("outer guard fired - read timeout did not");
    assert!(
        inner.is_err(),
        "expected Octocrab to surface a timeout error, got success: {inner:?}"
    );
    assert!(
        elapsed < Duration::from_secs(5),
        "read_timeout took too long to fire: {elapsed:?}"
    );
}
