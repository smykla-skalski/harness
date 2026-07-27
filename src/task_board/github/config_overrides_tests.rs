use super::config::{
    GitHubAutomationLabels, GitHubAutomationSettings, GitHubAutomationToggles, GitHubMergeMethod,
    GitHubRequestedReviewers, ProtectedPathRule,
};
use crate::task_board::TaskBoardRepositoryAutomationConfig;

fn global() -> GitHubAutomationSettings {
    let mut settings = GitHubAutomationSettings::default();
    settings.requested_reviewers = GitHubRequestedReviewers {
        reviewers: vec!["global-reviewer".to_owned()],
        team_reviewers: vec!["global-team".to_owned()],
    };
    settings.protected_paths = vec![ProtectedPathRule::new("Cargo.toml")];
    settings.merge_method = GitHubMergeMethod::Squash;
    settings
}

fn repository(repository: &str) -> TaskBoardRepositoryAutomationConfig {
    TaskBoardRepositoryAutomationConfig {
        repository: repository.to_owned(),
        ..TaskBoardRepositoryAutomationConfig::default()
    }
}

#[test]
fn a_repository_with_no_overrides_keeps_every_global_value() {
    let global = global();

    let merged = global.merged_with(&repository("owner/plain"));

    assert_eq!(
        merged, global,
        "an override-free repository must publish exactly as the global settings say"
    );
}

#[test]
fn an_override_replaces_only_the_value_it_names() {
    let global = global();
    let mut work = repository("owner/work");
    work.requested_reviewers = Some(GitHubRequestedReviewers {
        reviewers: vec!["work-reviewer".to_owned()],
        team_reviewers: Vec::new(),
    });

    let merged = global.merged_with(&work);

    assert_eq!(merged.requested_reviewers.reviewers, ["work-reviewer"]);
    assert!(
        merged.requested_reviewers.team_reviewers.is_empty(),
        "an override replaces the whole reviewer set, so the global team must not leak in"
    );
    assert_eq!(
        merged.protected_paths, global.protected_paths,
        "a value the override does not name must still be inherited"
    );
}

/// The reason the issue exists: reviewers requested on repositories where they
/// do not belong. Two repositories, one override, two different answers.
#[test]
fn two_repositories_resolve_to_different_reviewers() {
    let global = global();
    let mut work = repository("owner/work");
    work.requested_reviewers = Some(GitHubRequestedReviewers {
        reviewers: vec!["work-reviewer".to_owned()],
        team_reviewers: Vec::new(),
    });

    let personal = global.merged_with(&repository("owner/personal"));
    let work = global.merged_with(&work);

    assert_ne!(
        personal.requested_reviewers, work.requested_reviewers,
        "the whole point is that one repository's reviewers do not reach another"
    );
    assert_eq!(personal.requested_reviewers.reviewers, ["global-reviewer"]);
}

#[test]
fn every_overridable_value_can_be_overridden() {
    let mut over = repository("owner/all");
    over.requested_reviewers = Some(GitHubRequestedReviewers::default());
    over.protected_paths = Some(vec![ProtectedPathRule::new("src/**")]);
    over.labels = Some(GitHubAutomationLabels {
        managed: "m".to_owned(),
        auto_merge: "am".to_owned(),
        needs_human: "nh".to_owned(),
        protected_path: "pp".to_owned(),
    });
    over.enabled_automations = Some(GitHubAutomationToggles { enabled: Vec::new() });

    let merged = global().merged_with(&over);

    assert_eq!(merged.requested_reviewers, GitHubRequestedReviewers::default());
    assert_eq!(
        merged.protected_paths.iter().map(|rule| rule.pattern.as_str()).collect::<Vec<_>>(),
        ["src/**"]
    );
    assert_eq!(merged.labels.managed, "m");
    assert!(merged.enabled_automations.enabled.is_empty());
}
