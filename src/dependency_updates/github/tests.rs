use super::*;
use super::types::PageInfo;
use super::types::RepositoryLabelNode;
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
    assert!(bundle[2].color.is_none(), "empty color string should normalize to None");

    let serialized = serde_json::to_string(&bundle).expect("serialize");
    assert!(
        serialized.contains("\"color\":\"d73a4a\""),
        "serialized JSON should keep color field: {serialized}"
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
