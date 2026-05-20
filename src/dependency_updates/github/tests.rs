use super::*;

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
fn page_limit_requires_cursor_for_continuation() {
    let page_info = PageInfo {
        has_next_page: true,
        end_cursor: None,
    };

    let error =
        next_cursor_or_scope_limit(&page_info, 1, SEARCH_PAGE_CAP, "scope").expect_err("cursor");

    assert!(error.message().contains("without a cursor"));
}
