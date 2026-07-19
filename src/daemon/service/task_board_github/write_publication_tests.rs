use crate::task_board::github::{GitHubAutomation, GitHubProjectConfig};
use crate::task_board::{TaskBoardWorkflowKind, TaskBoardWorkflowState};

use super::{
    default_publication_result, parse_publication_url, reconcile_publication_number,
    validate_publication_automations,
};

#[test]
fn ambiguous_publication_without_identity_fails_closed() {
    let error = reconcile_publication_number(None, None)
        .expect_err("identity-less recovery must not republish");

    assert!(
        error
            .to_string()
            .contains("identity is unavailable after an ambiguous outcome")
    );
}

#[test]
fn publication_identity_must_match_the_frozen_pull_request() {
    let error = reconcile_publication_number(Some(42), Some(41))
        .expect_err("mismatched publication identity");

    assert!(
        error
            .to_string()
            .contains("changed its frozen pull request")
    );
    assert_eq!(
        reconcile_publication_number(Some(42), Some(42)).expect("exact identity"),
        42
    );
}

#[test]
fn publication_url_parsing_is_canonical() {
    assert_eq!(
        parse_publication_url("https://github.com/example/compass/pull/42").expect("canonical URL"),
        ("example/compass".into(), 42)
    );
    assert!(parse_publication_url("https://example.com/example/compass/pull/42").is_err());
}

#[test]
fn write_launch_requires_kind_specific_publication_automations() {
    let mut config = GitHubProjectConfig::default();
    config.enabled_automations.enabled = vec![GitHubAutomation::WatchChecks];
    assert!(validate_publication_automations(&config, TaskBoardWorkflowKind::DefaultTask).is_err());
    assert!(validate_publication_automations(&config, TaskBoardWorkflowKind::PrFix).is_err());

    config.enabled_automations.enabled = vec![GitHubAutomation::CreateBranch];
    validate_publication_automations(&config, TaskBoardWorkflowKind::PrFix)
        .expect("PrFix CreateBranch admission");
    assert!(validate_publication_automations(&config, TaskBoardWorkflowKind::DefaultTask).is_err());

    config
        .enabled_automations
        .enabled
        .push(GitHubAutomation::OpenPullRequest);
    validate_publication_automations(&config, TaskBoardWorkflowKind::DefaultTask)
        .expect("DefaultTask publication admission");
}

#[test]
fn post_creation_metadata_failure_retains_pull_request_identity() {
    let workflow = TaskBoardWorkflowState {
        pr_number: Some(42),
        last_error: Some("reviewer request failed after pull request creation".into()),
        ..TaskBoardWorkflowState::default()
    };

    assert_eq!(
        default_publication_result(&workflow, None, true).expect("authoritative identity"),
        (42, true)
    );
}
