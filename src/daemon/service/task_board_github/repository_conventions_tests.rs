use crate::task_board::github::{GitHubAutomationSettings, GitHubRequestedReviewers};
use crate::task_board::{TaskBoardOrchestratorSettings, TaskBoardRepositoryAutomationConfig};

use super::repository_conventions;

fn settings_overriding(repository: &str) -> TaskBoardOrchestratorSettings {
    TaskBoardOrchestratorSettings {
        repositories: vec![TaskBoardRepositoryAutomationConfig {
            repository: repository.to_owned(),
            requested_reviewers: Some(GitHubRequestedReviewers {
                reviewers: vec!["work-reviewer".to_owned()],
                team_reviewers: Vec::new(),
            }),
            ..TaskBoardRepositoryAutomationConfig::default()
        }],
        ..TaskBoardOrchestratorSettings::default()
    }
}

fn defaults() -> GitHubAutomationSettings {
    GitHubAutomationSettings {
        requested_reviewers: GitHubRequestedReviewers {
            reviewers: vec!["global-reviewer".to_owned()],
            team_reviewers: Vec::new(),
        },
        ..GitHubAutomationSettings::default()
    }
}

#[test]
fn a_repository_override_survives_a_slug_that_is_not_canonical() {
    let settings = settings_overriding("kumahq/kuma");

    let conventions = repository_conventions(&settings, &defaults(), " KumaHQ/Kuma ");

    assert_eq!(
        conventions.requested_reviewers.reviewers,
        vec!["work-reviewer".to_owned()]
    );
}

#[test]
fn a_stored_override_matches_even_when_it_is_the_one_stored_uncanonically() {
    let settings = settings_overriding("KumaHQ/Kuma");

    let conventions = repository_conventions(&settings, &defaults(), "kumahq/kuma");

    assert_eq!(
        conventions.requested_reviewers.reviewers,
        vec!["work-reviewer".to_owned()]
    );
}

#[test]
fn another_repository_keeps_the_global_conventions() {
    let settings = settings_overriding("kumahq/kuma");

    let conventions = repository_conventions(&settings, &defaults(), "smykla/personal");

    assert_eq!(
        conventions.requested_reviewers.reviewers,
        vec!["global-reviewer".to_owned()]
    );
}

#[test]
fn a_repository_that_is_not_a_slug_keeps_the_global_conventions() {
    let settings = settings_overriding("kumahq/kuma");

    let conventions = repository_conventions(&settings, &defaults(), "kuma");

    assert_eq!(
        conventions.requested_reviewers.reviewers,
        vec!["global-reviewer".to_owned()]
    );
}
