use super::*;

#[test]
fn personal_issue_queries_use_github_all_state_form() {
    let repository = GitHubRepository {
        owner: "owner".into(),
        repo: "repo".into(),
    };
    let queries = personal_issue_queries(&repository, "octo-user");

    assert_eq!(
        queries,
        vec![
            "repo:owner/repo is:issue assignee:octo-user",
            "repo:owner/repo is:issue author:octo-user",
            "repo:owner/repo is:issue author:renovate[bot]",
        ]
    );
    assert!(queries.iter().all(|query| !query.contains("state:")));
}

#[test]
fn graphql_search_item_deserializes_label_names() {
    let payload = json!({
        "number": 42,
        "title": "Fix bug",
        "body": null,
        "url": "https://example.com/i/42",
        "state": "OPEN",
        "updatedAt": "2026-05-15T00:00:00Z",
        "labels": {
            "nodes": [{ "name": "needs-fix" }, { "name": "automation" }]
        }
    });

    let item: GitHubSearchIssuePullRequestItem =
        serde_json::from_value(payload).expect("deserialize search item");

    assert_eq!(
        item.label_names(),
        vec!["needs-fix".to_string(), "automation".to_string()]
    );
}

#[test]
fn issue_updated_at_response_deserializes_minimal_payload() {
    let payload = json!({
        "repository": {
            "issue": {
                "updatedAt": "2026-05-20T12:00:00Z"
            }
        }
    });
    let response: GitHubIssueUpdatedAtResponse =
        serde_json::from_value(payload).expect("deserialize issue timestamp");

    assert_eq!(
        response
            .repository
            .and_then(|repository| repository.issue)
            .map(|issue| issue.updated_at),
        Some("2026-05-20T12:00:00Z".to_string())
    );
}

#[test]
fn github_search_page_cap_keeps_total_hits_under_one_thousand() {
    assert_eq!(GITHUB_SEARCH_PAGE_CAP, 10);
}

#[test]
fn next_search_cursor_requires_cursor_when_more_pages_exist() {
    let error = next_search_cursor(
        1,
        "testing pagination",
        GitHubSearchPageInfo {
            has_next_page: true,
            end_cursor: None,
        },
    )
    .expect_err("missing cursor should fail");

    assert!(error.message().contains("next page without a cursor"));
}
