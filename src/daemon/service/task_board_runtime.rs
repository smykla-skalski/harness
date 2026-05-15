use std::collections::BTreeSet;

use crate::daemon::state;
use crate::errors::{CliError, CliErrorKind};
use crate::task_board::{
    ExternalProvider, ExternalSyncConfig, TaskBoardGitHubRepositoryToken,
    TaskBoardGitHubTokensSyncRequest, TaskBoardGitHubTokensSyncResponse,
    TaskBoardGitRepositoryOverride, TaskBoardGitRuntimeConfig, TaskBoardGitRuntimeProfile,
    TaskBoardTodoistTokenSyncRequest, TaskBoardTodoistTokenSyncResponse, normalize_repository_slug,
};

/// Load the persisted task-board git runtime config.
///
/// # Errors
/// Returns `CliError` when the daemon runtime config cannot be read.
pub fn task_board_git_runtime_config() -> Result<TaskBoardGitRuntimeConfig, CliError> {
    state::load_task_board_git_runtime_config()
}

/// Persist the task-board git runtime config after validation and normalization.
///
/// # Errors
/// Returns `CliError` when repository overrides are invalid/duplicated or the
/// daemon runtime config cannot be written.
pub fn update_task_board_git_runtime_config(
    request: &TaskBoardGitRuntimeConfig,
) -> Result<TaskBoardGitRuntimeConfig, CliError> {
    let normalized = normalized_runtime_config(request)?;
    let persisted = normalized.without_secrets();
    state::replace_task_board_git_runtime_secrets(&normalized);
    state::persist_task_board_git_runtime_config(&persisted)?;
    Ok(persisted)
}

/// Replace the in-memory GitHub token snapshot used by the daemon.
///
/// # Errors
/// Returns `CliError` when repository token overrides are invalid.
pub fn sync_task_board_github_tokens(
    request: &TaskBoardGitHubTokensSyncRequest,
) -> Result<TaskBoardGitHubTokensSyncResponse, CliError> {
    validate_repository_tokens(&request.repository_tokens)?;
    Ok(state::replace_task_board_github_tokens(request))
}

/// Replace the in-memory Todoist token snapshot used by the daemon.
#[must_use]
pub fn sync_task_board_todoist_token(
    request: &TaskBoardTodoistTokenSyncRequest,
) -> TaskBoardTodoistTokenSyncResponse {
    state::replace_task_board_todoist_token(request)
}

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
    if config.token_for(ExternalProvider::Todoist).is_none()
        && let Some(token) = state::task_board_todoist_token()
    {
        config = config.with_todoist_token_override(Some(token.as_str()));
    }
    config
}

pub(crate) fn git_runtime_profile_for_repository(
    repository: Option<&str>,
) -> Result<TaskBoardGitRuntimeProfile, CliError> {
    state::task_board_git_runtime_profile(repository)
}

fn normalized_runtime_config(
    request: &TaskBoardGitRuntimeConfig,
) -> Result<TaskBoardGitRuntimeConfig, CliError> {
    let global = request.global.normalized();
    let overrides = request
        .repository_overrides
        .iter()
        .map(|override_config| {
            override_config.normalized().ok_or_else(|| {
                CliError::from(CliErrorKind::workflow_parse(format!(
                    "invalid task-board repository override '{}', expected owner/repo",
                    override_config.repository
                )))
            })
        })
        .collect::<Result<Vec<_>, _>>()?;
    validate_unique_overrides(&overrides)?;
    Ok(TaskBoardGitRuntimeConfig {
        global,
        repository_overrides: overrides,
    })
}

fn validate_unique_overrides(overrides: &[TaskBoardGitRepositoryOverride]) -> Result<(), CliError> {
    let mut seen = BTreeSet::new();
    for override_config in overrides {
        if !seen.insert(override_config.repository.clone()) {
            return Err(CliError::from(CliErrorKind::workflow_parse(format!(
                "duplicate task-board repository override '{}'",
                override_config.repository
            ))));
        }
    }
    Ok(())
}

fn validate_repository_tokens(tokens: &[TaskBoardGitHubRepositoryToken]) -> Result<(), CliError> {
    let mut seen = BTreeSet::new();
    for token in tokens {
        let Some(repository) = normalize_repository_slug(Some(token.repository.as_str())) else {
            return Err(CliError::from(CliErrorKind::workflow_parse(format!(
                "invalid task-board repository token override '{}', expected owner/repo",
                token.repository
            ))));
        };
        if token.token.trim().is_empty() {
            return Err(CliError::from(CliErrorKind::workflow_parse(format!(
                "task-board repository token override '{repository}' cannot be empty"
            ))));
        }
        if !seen.insert(repository.clone()) {
            return Err(CliError::from(CliErrorKind::workflow_parse(format!(
                "duplicate task-board repository token override '{repository}'"
            ))));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use harness_testkit::with_isolated_harness_env;
    use tempfile::tempdir;

    use super::{
        TaskBoardGitHubRepositoryToken, TaskBoardGitHubTokensSyncRequest,
        TaskBoardGitRepositoryOverride, TaskBoardGitRuntimeConfig,
        TaskBoardTodoistTokenSyncRequest, update_task_board_git_runtime_config,
        validate_repository_tokens,
    };
    use crate::daemon::state;
    use crate::task_board::{
        TaskBoardGitRuntimeProfile, TaskBoardGitSigningConfig, TaskBoardGitSigningMode,
    };

    #[test]
    fn update_runtime_config_normalizes_and_persists_repository_overrides() {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            let saved = update_task_board_git_runtime_config(&TaskBoardGitRuntimeConfig {
                global: TaskBoardGitRuntimeProfile {
                    author_name: Some(" Global ".into()),
                    author_email: Some(" user@example.com ".into()),
                    ssh_key_path: Some(" /tmp/id_ed25519 ".into()),
                    ssh_private_key: None,
                    ssh_private_key_passphrase: None,
                    signing: TaskBoardGitSigningConfig {
                        mode: TaskBoardGitSigningMode::Ssh,
                        ssh_key_path: Some(" /tmp/id_sign ".into()),
                        ssh_private_key: None,
                        ssh_private_key_passphrase: None,
                        gpg_key_id: None,
                        gpg_private_key_path: None,
                        gpg_private_key: None,
                        gpg_private_key_passphrase: None,
                    },
                },
                repository_overrides: vec![TaskBoardGitRepositoryOverride {
                    repository: " Owner/Repo ".into(),
                    profile: TaskBoardGitRuntimeProfile {
                        author_name: None,
                        author_email: Some(" repo@example.com ".into()),
                        ssh_key_path: None,
                        ssh_private_key: None,
                        ssh_private_key_passphrase: None,
                        signing: TaskBoardGitSigningConfig::default(),
                    },
                }],
            })
            .expect("save runtime config");

            assert_eq!(saved.global.author_name.as_deref(), Some("Global"));
            assert_eq!(
                saved.global.author_email.as_deref(),
                Some("user@example.com")
            );
            assert_eq!(
                saved.global.ssh_key_path.as_deref(),
                Some("/tmp/id_ed25519")
            );
            assert_eq!(saved.repository_overrides[0].repository, "owner/repo");
            assert_eq!(
                state::load_task_board_git_runtime_config().expect("load runtime config"),
                saved
            );
        });
    }

    #[test]
    fn update_runtime_config_keeps_private_key_material_process_local() {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            let saved = update_task_board_git_runtime_config(&TaskBoardGitRuntimeConfig {
                global: TaskBoardGitRuntimeProfile {
                    ssh_private_key: Some("ssh-secret".into()),
                    ssh_private_key_passphrase: Some("ssh-passphrase".into()),
                    signing: TaskBoardGitSigningConfig {
                        mode: TaskBoardGitSigningMode::Gpg,
                        ssh_private_key: Some("signing-ssh-secret".into()),
                        ssh_private_key_passphrase: Some("signing-ssh-passphrase".into()),
                        gpg_key_id: Some("ABC123".into()),
                        gpg_private_key_path: Some("/tmp/private.asc".into()),
                        gpg_private_key: Some("gpg-secret".into()),
                        gpg_private_key_passphrase: Some("secret".into()),
                        ..Default::default()
                    },
                    ..Default::default()
                },
                repository_overrides: vec![],
            })
            .expect("save runtime config");

            assert!(saved.global.ssh_private_key.is_none());
            assert!(saved.global.ssh_private_key_passphrase.is_none());
            assert!(saved.global.signing.ssh_private_key.is_none());
            assert!(saved.global.signing.ssh_private_key_passphrase.is_none());
            assert!(saved.global.signing.gpg_private_key.is_none());
            assert!(saved.global.signing.gpg_private_key_passphrase.is_none());
            let raw_config = fs_err::read_to_string(state::config_path()).expect("read raw config");
            assert!(!raw_config.contains("ssh-secret"));
            assert!(!raw_config.contains("ssh-passphrase"));
            assert!(!raw_config.contains("signing-ssh-secret"));
            assert!(!raw_config.contains("signing-ssh-passphrase"));
            assert!(!raw_config.contains("gpg-secret"));
            assert!(!raw_config.contains("secret"));
            assert!(!raw_config.contains("\"ssh_private_key\""));
            assert!(!raw_config.contains("\"gpg_private_key\""));
            assert!(!raw_config.contains("gpg_private_key_passphrase"));
            assert!(
                state::load_task_board_git_runtime_config()
                    .expect("load persisted runtime config")
                    .global
                    .signing
                    .gpg_private_key_passphrase
                    .is_none()
            );
            let profile =
                super::git_runtime_profile_for_repository(None).expect("load signing profile");
            assert_eq!(profile.ssh_private_key.as_deref(), Some("ssh-secret"));
            assert_eq!(
                profile.ssh_private_key_passphrase.as_deref(),
                Some("ssh-passphrase")
            );
            assert_eq!(
                profile.signing.ssh_private_key.as_deref(),
                Some("signing-ssh-secret")
            );
            assert_eq!(
                profile.signing.ssh_private_key_passphrase.as_deref(),
                Some("signing-ssh-passphrase")
            );
            assert_eq!(
                profile.signing.gpg_private_key.as_deref(),
                Some("gpg-secret")
            );
            assert_eq!(
                profile.signing.gpg_private_key_passphrase.as_deref(),
                Some("secret")
            );
        });
    }

    #[test]
    fn validate_repository_tokens_rejects_invalid_and_duplicate_repositories() {
        let invalid = validate_repository_tokens(&[TaskBoardGitHubRepositoryToken {
            repository: "invalid".into(),
            token: "token".into(),
        }]);
        assert!(invalid.is_err());

        let duplicate = validate_repository_tokens(&[
            TaskBoardGitHubRepositoryToken {
                repository: "owner/repo".into(),
                token: "token-1".into(),
            },
            TaskBoardGitHubRepositoryToken {
                repository: "OWNER/REPO".into(),
                token: "token-2".into(),
            },
        ]);
        assert!(duplicate.is_err());

        validate_repository_tokens(&[TaskBoardGitHubRepositoryToken {
            repository: "owner/repo".into(),
            token: "token".into(),
        }])
        .expect("valid token overrides");
    }

    #[test]
    fn sync_tokens_replace_existing_snapshot() {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            super::sync_task_board_github_tokens(&TaskBoardGitHubTokensSyncRequest {
                global_token: Some("global".into()),
                repository_tokens: vec![TaskBoardGitHubRepositoryToken {
                    repository: "owner/repo".into(),
                    token: "repo-token".into(),
                }],
            })
            .expect("seed tokens");
            assert_eq!(
                state::task_board_github_token(Some("owner/repo")).as_deref(),
                Some("repo-token")
            );

            super::sync_task_board_github_tokens(&TaskBoardGitHubTokensSyncRequest::default())
                .expect("clear tokens");
            assert!(state::task_board_github_token(Some("owner/repo")).is_none());
            assert!(state::task_board_github_token(None).is_none());
        });
    }

    #[test]
    fn external_sync_config_uses_app_configured_todoist_token_when_env_missing() {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            let _ =
                super::sync_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest::default());
            let _ = super::sync_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest {
                token: Some(" todoist-token ".into()),
            });

            let config = super::external_sync_config_for_repository(Some("owner/repo"), &[]);

            assert_eq!(
                config.token_for(crate::task_board::ExternalProvider::Todoist),
                Some("todoist-token")
            );
            let _ =
                super::sync_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest::default());
        });
    }

    #[test]
    fn external_sync_config_keeps_todoist_env_precedence() {
        let tmp = tempdir().expect("tempdir");
        with_isolated_harness_env(tmp.path(), || {
            let _ =
                super::sync_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest::default());
            temp_env::with_var("HARNESS_TODOIST_TOKEN", Some("env-token"), || {
                let _ = super::sync_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest {
                    token: Some("app-token".into()),
                });

                let config = super::external_sync_config_for_repository(Some("owner/repo"), &[]);

                assert_eq!(
                    config.token_for(crate::task_board::ExternalProvider::Todoist),
                    Some("env-token")
                );
            });
            let _ =
                super::sync_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest::default());
        });
    }
}
