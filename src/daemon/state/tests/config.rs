use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use super::super::{
    DaemonRuntimeConfig, config_path, load_persisted_log_level, load_runtime_config,
    load_task_board_git_runtime_config, persist_log_level, persist_task_board_git_runtime_config,
    read_recent_events, replace_task_board_github_tokens, replace_task_board_todoist_token,
    task_board_github_token, task_board_todoist_token,
};
use crate::task_board::{
    TaskBoardGitHubRepositoryToken, TaskBoardGitHubTokensSyncRequest, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeProfile, TaskBoardGitSigningConfig, TaskBoardGitSigningMode,
    TaskBoardTodoistTokenSyncRequest,
};

#[test]
fn runtime_config_round_trips_persisted_log_level() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        persist_log_level(Some("debug")).expect("persist log level");

        assert_eq!(
            load_runtime_config().expect("load runtime config"),
            Some(DaemonRuntimeConfig {
                log_level: Some("debug".into()),
                task_board_git_runtime_config: None,
            })
        );
    });
}

#[test]
fn persisted_log_level_normalizes_case_and_whitespace() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        persist_log_level(Some(" Trace ")).expect("persist log level");

        assert_eq!(
            load_persisted_log_level().expect("load persisted log level"),
            Some("trace".into())
        );
    });
}

#[test]
fn config_path_lives_under_daemon_root() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        assert_eq!(
            config_path(),
            tmp.path()
                .join("harness")
                .join("daemon")
                .join("config.json")
        );
    });
}

#[test]
fn persisted_log_level_rejects_invalid_values() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        super::super::ensure_daemon_dirs().expect("ensure daemon dirs");
        fs_err::write(config_path(), r#"{"log_level":"verbose"}"#).expect("write config");

        let error = load_persisted_log_level()
            .expect_err("invalid persisted log level should fail validation");
        assert!(error.to_string().contains(
            "invalid log level 'verbose', expected one of: trace, debug, info, warn, error"
        ));
    });
}

#[test]
fn persist_log_level_replaces_malformed_runtime_config() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        super::super::ensure_daemon_dirs().expect("ensure daemon dirs");
        fs_err::write(config_path(), "{not-json").expect("write config");

        persist_log_level(Some("debug")).expect("persist repaired log level");

        assert_eq!(
            load_runtime_config().expect("load repaired runtime config"),
            Some(DaemonRuntimeConfig {
                log_level: Some("debug".into()),
                task_board_git_runtime_config: None,
            })
        );

        let event = read_recent_events(1)
            .expect("read daemon events")
            .pop()
            .expect("repair warning event");
        assert_eq!(event.level, "warn");
        assert!(
            event
                .message
                .contains("replacing invalid daemon runtime config")
        );
    });
}

#[test]
fn runtime_config_round_trips_task_board_git_runtime_config() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        persist_task_board_git_runtime_config(&TaskBoardGitRuntimeConfig {
            global: TaskBoardGitRuntimeProfile {
                author_name: Some("Harness Bot".into()),
                author_email: Some("bot@example.com".into()),
                ssh_key_path: Some("/tmp/id_ed25519".into()),
                ssh_private_key: Some("ssh-secret".into()),
                ssh_private_key_passphrase: Some("ssh-passphrase".into()),
                signing: TaskBoardGitSigningConfig {
                    mode: TaskBoardGitSigningMode::Gpg,
                    ssh_key_path: None,
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
        .expect("persist task-board runtime config");

        assert_eq!(
            load_task_board_git_runtime_config().expect("load task-board runtime config"),
            TaskBoardGitRuntimeConfig {
                global: TaskBoardGitRuntimeProfile {
                    author_name: Some("Harness Bot".into()),
                    author_email: Some("bot@example.com".into()),
                    ssh_key_path: Some("/tmp/id_ed25519".into()),
                    ssh_private_key: None,
                    ssh_private_key_passphrase: None,
                    ssh_private_key_configured: true,
                    ssh_private_key_passphrase_configured: true,
                    signing: TaskBoardGitSigningConfig {
                        mode: TaskBoardGitSigningMode::Gpg,
                        ssh_key_path: None,
                        ssh_private_key: None,
                        ssh_private_key_passphrase: None,
                        gpg_key_id: Some("ABC123".into()),
                        gpg_private_key_path: Some("/tmp/private.asc".into()),
                        gpg_private_key: None,
                        gpg_private_key_passphrase: None,
                        ssh_private_key_configured: true,
                        ssh_private_key_passphrase_configured: true,
                        gpg_private_key_configured: true,
                        gpg_private_key_passphrase_configured: true,
                    },
                },
                repository_overrides: vec![],
            }
        );
    });
}

#[test]
fn github_token_snapshot_prefers_repository_override() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let response = replace_task_board_github_tokens(&TaskBoardGitHubTokensSyncRequest {
            global_token: Some("global-token".into()),
            repository_tokens: vec![TaskBoardGitHubRepositoryToken {
                repository: "owner/repo".into(),
                token: "repo-token".into(),
            }],
        });

        assert!(response.global_token_configured);
        assert_eq!(response.repository_token_count, 1);
        assert_eq!(
            task_board_github_token(Some("OWNER/REPO")).as_deref(),
            Some("repo-token")
        );
        assert_eq!(
            task_board_github_token(Some("other/repo")).as_deref(),
            Some("global-token")
        );
    });
}

#[test]
fn task_board_credential_snapshots_are_scoped_by_daemon_root() {
    let first = tempdir().expect("first tempdir");
    let second = tempdir().expect("second tempdir");

    with_isolated_harness_env(first.path(), || {
        let _ = replace_task_board_github_tokens(&TaskBoardGitHubTokensSyncRequest {
            global_token: Some("first-gh".into()),
            repository_tokens: vec![],
        });
        let _ = replace_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest {
            token: Some("first-todoist".into()),
        });
    });

    with_isolated_harness_env(second.path(), || {
        assert!(task_board_github_token(None).is_none());
        assert!(task_board_todoist_token().is_none());

        let _ = replace_task_board_github_tokens(&TaskBoardGitHubTokensSyncRequest {
            global_token: Some("second-gh".into()),
            repository_tokens: vec![],
        });
        let _ = replace_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest {
            token: Some("second-todoist".into()),
        });

        assert_eq!(task_board_github_token(None).as_deref(), Some("second-gh"));
        assert_eq!(
            task_board_todoist_token().as_deref(),
            Some("second-todoist")
        );
    });

    with_isolated_harness_env(first.path(), || {
        assert_eq!(task_board_github_token(None).as_deref(), Some("first-gh"));
        assert_eq!(task_board_todoist_token().as_deref(), Some("first-todoist"));
    });
}
