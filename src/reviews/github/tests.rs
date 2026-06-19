use super::queries::{NODES_BY_IDS_QUERY, SEARCH_QUERY};
use super::types::PageInfo;
use super::types::RepositoryLabelNode;
use super::*;
use crate::reviews::ReviewRepositoryLabel;

mod check_contexts;

#[test]
fn scope_query_cap_rejects_broad_cartesian_requests() {
    let request = ReviewsQueryRequest {
        authors: (0..6).map(|index| format!("author-{index}")).collect(),
        organizations: (0..6).map(|index| format!("org-{index}")).collect(),
        repositories: (0..3).map(|index| format!("acme/repo-{index}")).collect(),
        exclude_repositories: Vec::new(),
        force_refresh: false,
        cache_max_age_seconds: 600,
        ..ReviewsQueryRequest::default()
    };

    assert!(scopes(&request).is_err());
}

#[test]
fn normalize_git_blob_base64_strips_github_line_wrapping() {
    let wrapped = "aGVs\nbG8=\r\n";

    assert_eq!(normalize_git_blob_base64(wrapped), "aGVsbG8=");
}

#[test]
fn scopes_drop_author_clause_when_authors_empty() {
    let request = ReviewsQueryRequest {
        authors: Vec::new(),
        organizations: vec!["acme".into()],
        repositories: vec!["acme/api".into()],
        exclude_repositories: Vec::new(),
        force_refresh: false,
        cache_max_age_seconds: 600,
        ..ReviewsQueryRequest::default()
    };
    let queries = scopes(&request)
        .expect("scopes")
        .into_iter()
        .map(|scope| scope.query)
        .collect::<Vec<_>>();

    assert_eq!(
        queries,
        vec!["org:acme is:pr is:open", "repo:acme/api is:pr is:open",]
    );
}

#[test]
fn scopes_keep_review_searches_author_scoped() {
    let request = ReviewsQueryRequest {
        authors: vec!["renovate[bot]".into(), "octo-user".into()],
        organizations: vec!["acme".into()],
        repositories: vec!["acme/api".into()],
        exclude_repositories: Vec::new(),
        force_refresh: false,
        cache_max_age_seconds: 600,
        ..ReviewsQueryRequest::default()
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
fn search_descriptor_marks_forced_refreshes_uncacheable() {
    let mut request = ReviewsQueryRequest {
        authors: Vec::new(),
        organizations: Vec::new(),
        repositories: vec!["kong/kong-mesh".into()],
        exclude_repositories: Vec::new(),
        force_refresh: true,
        cache_max_age_seconds: 600,
        ..ReviewsQueryRequest::default()
    };

    let forced = super::fetch::search_descriptor(&request);
    assert_eq!(
        forced.priority,
        crate::github_api::GitHubPriority::FreshRead
    );
    assert!(forced.cache_policy.force_refresh);

    request.force_refresh = false;
    let background = super::fetch::search_descriptor(&request);
    assert_eq!(
        background.priority,
        crate::github_api::GitHubPriority::Background
    );
    assert!(!background.cache_policy.force_refresh);
}

#[test]
fn page_limit_requires_narrower_review_scope() {
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
    let mut bundle: Vec<ReviewRepositoryLabel> = Vec::new();
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
fn review_queries_request_author_association_and_review_requests() {
    assert!(
        SEARCH_QUERY.contains("authorAssociation"),
        "search query must request authorAssociation for row halo semantics"
    );
    assert!(
        SEARCH_QUERY.contains("reviewRequests(first: 100)"),
        "search query must request reviewRequests for reviewer-specific needs-me state"
    );
    assert!(
        SEARCH_QUERY.contains("requestedReviewer"),
        "search query must request requestedReviewer details"
    );
    assert!(
        NODES_BY_IDS_QUERY.contains("authorAssociation"),
        "nodes query must request authorAssociation for refresh parity"
    );
    assert!(
        NODES_BY_IDS_QUERY.contains("reviewRequests(first: 100)"),
        "nodes query must request reviewRequests for refresh parity"
    );
    assert!(
        NODES_BY_IDS_QUERY.contains("requestedReviewer"),
        "nodes query must request requestedReviewer details for refresh parity"
    );
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

#[test]
fn production_github_timeouts_match_documented_ceilings() {
    assert_eq!(
        GITHUB_HTTP_CONNECT_TIMEOUT,
        std::time::Duration::from_secs(30)
    );
    assert_eq!(GITHUB_HTTP_READ_TIMEOUT, std::time::Duration::from_secs(60));
}

#[test]
fn protected_github_client_rejects_empty_token() {
    let Err(error) = crate::github_api::GitHubProtectedClient::new("  ") else {
        panic!("empty token should fail");
    };

    assert!(error.message().contains("github token missing"));
}
