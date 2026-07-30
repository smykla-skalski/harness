pub(crate) use harness_task_board_git_runtime::external_sync_config_for_repository;

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
