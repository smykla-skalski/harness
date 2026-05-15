use temp_env::with_vars;

use crate::task_board::{
    ExternalProvider, ExternalRefProvider, ExternalSyncClient, ExternalSyncConfig, ExternalTaskRef,
    GH_TOKEN_ENV, GITHUB_REPOSITORY_ENV, GitHubInboxSyncClient, GitHubSyncClient,
    HARNESS_GITHUB_REPOSITORY_ENV, HARNESS_GITHUB_TOKEN_ENV, HARNESS_TODOIST_TOKEN_ENV,
    TodoistSyncClient,
};

#[test]
fn env_config_prefers_harness_github_token() {
    let config = with_vars(
        [
            (HARNESS_GITHUB_TOKEN_ENV, Some(" harness-token ")),
            (HARNESS_GITHUB_REPOSITORY_ENV, Some(" owner/repo ")),
            (GITHUB_REPOSITORY_ENV, Some("fallback/repo")),
            (GH_TOKEN_ENV, Some("gh-token")),
            (HARNESS_TODOIST_TOKEN_ENV, Some("todoist-token")),
        ],
        ExternalSyncConfig::from_env,
    );

    assert_eq!(
        config.token_for(ExternalProvider::GitHub),
        Some("harness-token")
    );
    assert_eq!(
        config.token_for(ExternalProvider::Todoist),
        Some("todoist-token")
    );
    assert_eq!(config.github_repository.as_deref(), Some("owner/repo"));
}

#[test]
fn env_config_falls_back_to_gh_token() {
    let config = with_vars(
        [
            (HARNESS_GITHUB_TOKEN_ENV, None::<&str>),
            (HARNESS_GITHUB_REPOSITORY_ENV, None::<&str>),
            (GITHUB_REPOSITORY_ENV, None::<&str>),
            (GH_TOKEN_ENV, Some("gh-token")),
            (HARNESS_TODOIST_TOKEN_ENV, None::<&str>),
        ],
        ExternalSyncConfig::from_env,
    );

    assert_eq!(config.token_for(ExternalProvider::GitHub), Some("gh-token"));
    assert_eq!(config.token_for(ExternalProvider::Todoist), None);
}

#[test]
fn config_debug_redacts_tokens() {
    let config = ExternalSyncConfig {
        github_token: Some("secret".to_owned()),
        github_repository: Some("owner/repo".to_owned()),
        github_inbox_repositories: Vec::new(),
        todoist_token: None,
    };

    let debug = format!("{config:?}");
    assert!(debug.contains("<redacted>"));
    assert!(debug.contains("<unset>"));
    assert!(debug.contains("owner/repo"));
    assert!(!debug.contains("secret"));
}

#[test]
fn github_constructor_validates_default_repository() {
    let err = GitHubSyncClient::new_with_repository("token", Some("invalid"))
        .expect_err("invalid repository should fail")
        .message();

    assert!(err.contains("owner/repo"));
}

#[test]
fn external_ref_round_trips_to_core_ref() {
    let reference = ExternalTaskRef::new(ExternalProvider::GitHub, "issue-7")
        .with_url("https://example.test/7");

    let core = reference.clone().into_core_ref();
    assert_eq!(core.provider, ExternalRefProvider::GitHub);
    assert_eq!(core.external_id, "issue-7");

    let restored = ExternalTaskRef::from(core);
    assert_eq!(restored, reference);
}

#[test]
fn provider_constructors_require_tokens_without_network() {
    let config = ExternalSyncConfig::default();

    let github_error = GitHubSyncClient::from_config(&config)
        .expect_err("missing github token should fail")
        .message();
    let todoist_error = TodoistSyncClient::from_config(&config)
        .expect_err("missing todoist token should fail")
        .message();

    assert!(github_error.contains(HARNESS_GITHUB_TOKEN_ENV));
    assert!(github_error.contains(GH_TOKEN_ENV));
    assert!(todoist_error.contains(HARNESS_TODOIST_TOKEN_ENV));
}

#[test]
fn github_repository_fallback_is_used_only_when_env_is_missing() {
    let from_fallback =
        ExternalSyncConfig::default().with_github_repository_fallback(Some(" owner/repo "));
    let from_env = ExternalSyncConfig {
        github_token: None,
        github_repository: Some("env/repo".to_string()),
        github_inbox_repositories: Vec::new(),
        todoist_token: None,
    }
    .with_github_repository_fallback(Some("owner/repo"));

    assert_eq!(from_fallback.github_repository(), Some("owner/repo"));
    assert_eq!(from_env.github_repository(), Some("env/repo"));
}

#[tokio::test]
async fn github_inbox_client_is_pull_only() {
    let repositories = vec!["owner/repo".to_string()];
    let config = ExternalSyncConfig::default()
        .with_github_token_override(Some("token"))
        .with_github_inbox_repositories_override(&repositories);

    let client = GitHubInboxSyncClient::from_config(&config).expect("build inbox client");

    assert!(client.allows_pull());
    assert!(!client.allows_push());
}

#[tokio::test]
async fn github_sync_client_can_disable_pull_for_inbox_overlap() {
    let config = ExternalSyncConfig::default()
        .with_github_token_override(Some("token"))
        .with_github_repository_override(Some("owner/repo"));

    let client =
        GitHubSyncClient::from_config_with_pull(&config, false).expect("build github client");

    assert!(!client.allows_pull());
    assert!(client.allows_push());
}
