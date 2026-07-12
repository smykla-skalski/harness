use std::fs;

use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use super::super::{
    DaemonRuntimeConfig, config_path, load_persisted_log_level, load_runtime_config,
    load_runtime_config_raw, load_task_board_git_runtime_config, persist_log_level,
    persist_task_board_git_runtime_config, read_recent_events,
    remove_migrated_task_board_config_after_ack, replace_task_board_git_runtime_secrets,
    replace_task_board_github_tokens, replace_task_board_openrouter_token,
    replace_task_board_todoist_token, task_board_git_runtime_secret_handoff_digest,
    task_board_github_token, task_board_openrouter_token, task_board_todoist_token,
};
use crate::task_board::{
    TaskBoardGitHubRepositoryToken, TaskBoardGitHubTokensSyncRequest, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeProfile, TaskBoardGitSigningConfig, TaskBoardGitSigningMode,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardTodoistTokenSyncRequest,
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
                .join(crate::daemon::state::DaemonOwnership::Managed.as_str())
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
        // Mirror the production flow: persist the non-secret view to disk and
        // keep the secret material process-local. The `*_configured` flags on
        // the load path are derived from the in-memory secret state, never
        // from disk, so the test seeds both sides.
        let runtime = TaskBoardGitRuntimeConfig {
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
        };

        persist_task_board_git_runtime_config(&runtime).expect("persist task-board runtime config");
        replace_task_board_git_runtime_secrets(&runtime);

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

        // The on-disk view must contain neither secret material nor the
        // wire-only `*_configured` indicators. The privacy contract is that
        // both never reach disk.
        let raw = fs::read_to_string(config_path()).expect("read raw config");
        assert!(!raw.contains("ssh-secret"));
        assert!(!raw.contains("ssh-passphrase"));
        assert!(!raw.contains("signing-ssh-secret"));
        assert!(!raw.contains("signing-ssh-passphrase"));
        assert!(!raw.contains("gpg-secret"));
        assert!(!raw.contains("\"ssh_private_key\""));
        assert!(!raw.contains("\"gpg_private_key\""));
        assert!(!raw.contains("_configured"));
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
fn handoff_digest_is_absent_when_disk_config_is_already_stripped() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        assert!(
            task_board_git_runtime_secret_handoff_digest(&TaskBoardGitRuntimeConfig::default())
                .expect("digest empty config")
                .is_none()
        );

        persist_task_board_git_runtime_config(&TaskBoardGitRuntimeConfig {
            global: TaskBoardGitRuntimeProfile {
                author_name: Some("Bot".into()),
                ssh_private_key: Some("stripped-on-persist".into()),
                ..Default::default()
            },
            repository_overrides: vec![],
        })
        .expect("persist stripped config");

        assert!(
            task_board_git_runtime_secret_handoff_digest(
                &load_runtime_config_raw()
                    .expect("load raw config")
                    .and_then(|config| config.task_board_git_runtime_config)
                    .unwrap_or_default()
            )
            .expect("digest stripped config")
            .is_none()
        );
    });
}

#[test]
fn handoff_digest_is_stable_and_does_not_strip_plaintext() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let raw_disk = serde_json::json!({
            "task_board_git_runtime_config": {
                "global": {
                    "author_name": "Bot",
                    "ssh_private_key": "global-ssh-secret",
                    "ssh_private_key_passphrase": "global-pass",
                    "signing": {
                        "mode": "gpg",
                        "gpg_private_key": "global-gpg-secret",
                        "gpg_private_key_passphrase": "gpg-pass"
                    }
                },
                "repository_overrides": [
                    {
                        "repository": "owner/repo",
                        "profile": {
                            "ssh_private_key": "repo-ssh-secret"
                        }
                    }
                ]
            }
        });
        fs::create_dir_all(config_path().parent().expect("parent")).expect("mkdir");
        fs::write(
            config_path(),
            serde_json::to_string_pretty(&raw_disk).expect("encode"),
        )
        .expect("write raw config");

        let raw = load_runtime_config_raw()
            .expect("load plaintext config")
            .and_then(|config| config.task_board_git_runtime_config)
            .expect("task board config");
        let digest = task_board_git_runtime_secret_handoff_digest(&raw)
            .expect("digest plaintext config")
            .expect("plaintext produces digest");
        let second_digest = task_board_git_runtime_secret_handoff_digest(&raw)
            .expect("digest again")
            .expect("plaintext still produces digest");
        assert_eq!(digest, second_digest);
        assert_eq!(digest.len(), 64);
        assert_eq!(
            raw.global.ssh_private_key.as_deref(),
            Some("global-ssh-secret")
        );
        assert_eq!(
            raw.global.signing.gpg_private_key.as_deref(),
            Some("global-gpg-secret")
        );
        assert_eq!(raw.repository_overrides.len(), 1);
        assert_eq!(
            raw.repository_overrides[0]
                .profile
                .ssh_private_key
                .as_deref(),
            Some("repo-ssh-secret")
        );
        let still_on_disk = fs::read_to_string(config_path()).expect("read legacy payload");
        assert!(still_on_disk.contains("global-ssh-secret"));
    });
}

#[test]
fn acknowledged_handoff_cleanup_rejects_changed_plaintext() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let original = TaskBoardGitRuntimeConfig {
            global: TaskBoardGitRuntimeProfile {
                ssh_private_key: Some("original-secret".into()),
                ..Default::default()
            },
            repository_overrides: vec![],
        };
        let changed = TaskBoardGitRuntimeConfig {
            global: TaskBoardGitRuntimeProfile {
                ssh_private_key: Some("replacement-secret".into()),
                ..Default::default()
            },
            repository_overrides: vec![],
        };
        let digest = task_board_git_runtime_secret_handoff_digest(&original)
            .expect("digest original")
            .expect("plaintext digest");
        fs::create_dir_all(config_path().parent().expect("parent")).expect("mkdir");
        fs::write(
            config_path(),
            serde_json::to_vec_pretty(&DaemonRuntimeConfig {
                log_level: None,
                task_board_git_runtime_config: Some(changed),
            })
            .expect("encode changed config"),
        )
        .expect("write changed config");

        let error = remove_migrated_task_board_config_after_ack(&digest)
            .expect_err("changed payload must survive cleanup");

        assert!(error.to_string().contains("payload changed"));
        assert!(
            fs::read_to_string(config_path())
                .expect("read retained config")
                .contains("replacement-secret")
        );
    });
}

#[test]
fn acknowledged_handoff_cleanup_removes_matching_envelope() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let runtime = TaskBoardGitRuntimeConfig {
            global: TaskBoardGitRuntimeProfile {
                ssh_private_key: Some("migrated-secret".into()),
                ..Default::default()
            },
            repository_overrides: vec![],
        };
        let digest = task_board_git_runtime_secret_handoff_digest(&runtime)
            .expect("digest runtime")
            .expect("plaintext digest");
        fs::create_dir_all(config_path().parent().expect("parent")).expect("mkdir");
        fs::write(
            config_path(),
            serde_json::to_vec_pretty(&DaemonRuntimeConfig {
                log_level: Some("debug".into()),
                task_board_git_runtime_config: Some(runtime),
            })
            .expect("encode config"),
        )
        .expect("write config");

        assert!(
            remove_migrated_task_board_config_after_ack(&digest).expect("remove matching envelope")
        );
        let stored = load_runtime_config_raw()
            .expect("load cleaned config")
            .expect("log-level config remains");
        assert_eq!(stored.log_level.as_deref(), Some("debug"));
        assert!(stored.task_board_git_runtime_config.is_none());
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
        let _ = replace_task_board_openrouter_token(&TaskBoardOpenRouterTokenSyncRequest {
            token: Some("first-or".into()),
        });
    });

    with_isolated_harness_env(second.path(), || {
        assert!(task_board_github_token(None).is_none());
        assert!(task_board_todoist_token().is_none());
        assert!(task_board_openrouter_token().is_none());

        let _ = replace_task_board_github_tokens(&TaskBoardGitHubTokensSyncRequest {
            global_token: Some("second-gh".into()),
            repository_tokens: vec![],
        });
        let _ = replace_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest {
            token: Some("second-todoist".into()),
        });
        let _ = replace_task_board_openrouter_token(&TaskBoardOpenRouterTokenSyncRequest {
            token: Some("second-or".into()),
        });

        assert_eq!(task_board_github_token(None).as_deref(), Some("second-gh"));
        assert_eq!(
            task_board_todoist_token().as_deref(),
            Some("second-todoist")
        );
        assert_eq!(task_board_openrouter_token().as_deref(), Some("second-or"));
    });

    with_isolated_harness_env(first.path(), || {
        assert_eq!(task_board_github_token(None).as_deref(), Some("first-gh"));
        assert_eq!(task_board_todoist_token().as_deref(), Some("first-todoist"));
        assert_eq!(task_board_openrouter_token().as_deref(), Some("first-or"));
    });
}
