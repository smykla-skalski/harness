use crate::daemon::state;
use crate::task_board::{ExternalProvider, ExternalSyncConfig, normalize_repository_slug};

pub(crate) fn external_sync_config_for_repository(
    repository: Option<&str>,
    inbox_repositories: &[String],
) -> ExternalSyncConfig {
    let repository = normalize_repository_slug(repository);
    let mut config = ExternalSyncConfig::from_env();
    if let Some(token) = repository
        .as_deref()
        .and_then(state::task_board_github_repository_token)
        .or_else(|| {
            config
                .token_for(ExternalProvider::GitHub)
                .is_none()
                .then(|| state::task_board_github_token(None))
                .flatten()
        })
    {
        config = config.with_github_token_override(Some(token.as_str()));
    }
    if let Some(repository) = repository.as_deref() {
        config = config.with_github_repository_override(Some(repository));
    }
    config = config.with_github_inbox_repositories_override(inbox_repositories);
    config
}

#[cfg(test)]
mod tests {
    use harness_testkit::with_isolated_harness_env;
    use tempfile::tempdir;

    use crate::daemon::protocol::TaskBoardGitHubTokensSyncRequest;
    use crate::task_board::{ExternalProvider, TaskBoardGitHubRepositoryToken};

    #[test]
    fn external_sync_config_uses_app_configured_github_token_when_env_missing() {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            let _ = super::super::task_board_runtime::sync_task_board_github_tokens(
                &TaskBoardGitHubTokensSyncRequest::default(),
            );
            let _ = super::super::task_board_runtime::sync_task_board_github_tokens(
                &TaskBoardGitHubTokensSyncRequest {
                    global_token: Some(" github-token ".into()),
                    repository_tokens: Vec::new(),
                },
            );

            let config = super::external_sync_config_for_repository(Some("owner/repo"), &[]);

            assert_eq!(
                config.token_for(ExternalProvider::GitHub),
                Some("github-token")
            );
            let _ = super::super::task_board_runtime::sync_task_board_github_tokens(
                &TaskBoardGitHubTokensSyncRequest::default(),
            );
        });
    }

    #[test]
    fn external_sync_config_keeps_github_env_precedence() {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            let _ = super::super::task_board_runtime::sync_task_board_github_tokens(
                &TaskBoardGitHubTokensSyncRequest::default(),
            );
            temp_env::with_var("HARNESS_GITHUB_TOKEN", Some("env-token"), || {
                let _ = super::super::task_board_runtime::sync_task_board_github_tokens(
                    &TaskBoardGitHubTokensSyncRequest {
                        global_token: Some("app-token".into()),
                        repository_tokens: Vec::new(),
                    },
                );

                let config = super::external_sync_config_for_repository(Some("owner/repo"), &[]);

                assert_eq!(
                    config.token_for(ExternalProvider::GitHub),
                    Some("env-token")
                );
            });
            let _ = super::super::task_board_runtime::sync_task_board_github_tokens(
                &TaskBoardGitHubTokensSyncRequest::default(),
            );
        });
    }

    #[test]
    fn external_sync_config_prefers_repository_token() {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            let _ = super::super::task_board_runtime::sync_task_board_github_tokens(
                &TaskBoardGitHubTokensSyncRequest {
                    global_token: Some("global-token".into()),
                    repository_tokens: vec![TaskBoardGitHubRepositoryToken {
                        repository: "owner/repo".into(),
                        token: "repository-token".into(),
                    }],
                },
            );

            let config = super::external_sync_config_for_repository(Some("owner/repo"), &[]);

            assert_eq!(
                config.token_for(ExternalProvider::GitHub),
                Some("repository-token")
            );
            let _ = super::super::task_board_runtime::sync_task_board_github_tokens(
                &TaskBoardGitHubTokensSyncRequest::default(),
            );
        });
    }
}
