use std::collections::BTreeMap;

use super::*;
use crate::task_board::ExternalRef;

fn github_item(project_id: Option<&str>, execution_repository: Option<&str>) -> TaskBoardItem {
    let mut item = TaskBoardItem::new(
        "board-item".into(),
        "Fix the thing".into(),
        "Acceptance criteria".into(),
        "2026-07-26T10:00:00Z".into(),
    );
    item.project_id = project_id.map(Into::into);
    item.execution_repository = execution_repository.map(Into::into);
    item.external_refs = vec![ExternalRef {
        provider: ExternalRefProvider::GitHub,
        external_id: "example/compass#42".into(),
        url: Some("https://github.com/example/compass/issues/42".into()),
        sync_state: None,
    }];
    item
}

fn config_for(owner: &str, repo: &str) -> GitHubProjectConfig {
    let mut config = GitHubProjectConfig::default();
    config.owner = owner.into();
    config.repo = repo.into();
    config
}

/// A GitHub import leaves `project_id` null and puts the slug in
/// `execution_repository`, which describes almost every item on a synced board.
#[test]
fn imported_items_still_close_their_issue() {
    let body = pull_request_body(
        &github_item(None, Some("example/compass")),
        &config_for("example", "compass"),
    );

    assert!(body.contains("Closes #42"), "unexpected body: {body}");
}

#[test]
fn legacy_bare_issue_numbers_still_close_their_issue() {
    let mut item = github_item(None, Some("example/compass"));
    item.external_refs[0].external_id = "42".into();

    let body = pull_request_body(&item, &config_for("example", "compass"));

    assert!(body.contains("Closes #42"), "unexpected body: {body}");
}

#[test]
fn a_differently_cased_repository_still_closes_its_issue() {
    let body = pull_request_body(
        &github_item(Some("Example/Compass"), None),
        &config_for("example", "compass"),
    );

    assert!(body.contains("Closes #42"), "unexpected body: {body}");
}

#[test]
fn an_item_from_another_repository_does_not_close_an_issue() {
    let body = pull_request_body(
        &github_item(None, Some("another-owner/atlas")),
        &config_for("example", "compass"),
    );

    assert!(!body.contains("Closes"), "unexpected body: {body}");
}

#[test]
fn an_item_with_no_repository_does_not_close_an_issue() {
    let body = pull_request_body(&github_item(None, None), &config_for("example", "compass"));

    assert!(!body.contains("Closes"), "unexpected body: {body}");
}

#[test]
fn publication_requires_an_item_specific_worktree() {
    let item = github_item(None, Some("example/compass"));

    assert_eq!(
        resolve_worktree(&item, &item.workflow, &BTreeMap::new()),
        None
    );
}
