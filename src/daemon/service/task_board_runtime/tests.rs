use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use super::{
    TaskBoardGitHubRepositoryToken, TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitRepositoryOverride, TaskBoardGitRuntimeConfig,
    TaskBoardGitRuntimeKeyMaterialSyncRequest, TaskBoardGitRuntimeSecretHandoffAckRequest,
    TaskBoardTodoistTokenSyncRequest, update_task_board_git_runtime_config,
    validate_repository_tokens,
};

#[test]
fn runtime_key_material_sync_never_persists_durable_config() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let response = super::sync_task_board_git_runtime_key_material(
            &TaskBoardGitRuntimeKeyMaterialSyncRequest {
                runtime: TaskBoardGitRuntimeConfig {
                    global: TaskBoardGitRuntimeProfile {
                        ssh_private_key: Some("process-secret".into()),
                        ..Default::default()
                    },
                    repository_overrides: vec![],
                },
            },
        )
        .expect("sync key material");
        assert!(response.synchronized);
        assert_eq!(
            super::git_runtime_profile_for_repository(None)
                .expect("runtime profile")
                .ssh_private_key
                .as_deref(),
            Some("process-secret")
        );
        assert!(!state::config_path().exists());
    });
}

#[test]
fn runtime_key_material_sync_retains_redacted_configured_secrets() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let sync = |runtime| {
            super::sync_task_board_git_runtime_key_material(
                &TaskBoardGitRuntimeKeyMaterialSyncRequest { runtime },
            )
            .expect("sync key material");
        };
        sync(TaskBoardGitRuntimeConfig {
            global: TaskBoardGitRuntimeProfile {
                ssh_private_key: Some("process-secret".into()),
                ..Default::default()
            },
            repository_overrides: vec![],
        });

        sync(TaskBoardGitRuntimeConfig {
            global: TaskBoardGitRuntimeProfile {
                ssh_private_key_configured: true,
                ..Default::default()
            },
            repository_overrides: vec![],
        });
        let retained = super::git_runtime_profile_for_repository(None).expect("runtime profile");
        assert_eq!(retained.ssh_private_key.as_deref(), Some("process-secret"));

        sync(TaskBoardGitRuntimeConfig::default());
        let cleared = super::git_runtime_profile_for_repository(None).expect("cleared profile");
        assert!(cleared.ssh_private_key.is_none());
    });
}
use crate::daemon::db::AsyncDaemonDb;
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
                    ..Default::default()
                },
                ..Default::default()
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
                    ..Default::default()
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
        let _ = super::sync_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest::default());
        let _ = super::sync_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest {
            token: Some(" todoist-token ".into()),
        });

        let config = super::external_sync_config_for_repository(Some("owner/repo"), &[]);

        assert_eq!(
            config.token_for(crate::task_board::ExternalProvider::Todoist),
            Some("todoist-token")
        );
        let _ = super::sync_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest::default());
    });
}

#[test]
fn secret_handoff_keeps_legacy_payload_until_ack_and_is_idempotent() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let runtime_config = TaskBoardGitRuntimeConfig {
            global: TaskBoardGitRuntimeProfile {
                ssh_private_key: Some("legacy-secret".into()),
                ..Default::default()
            },
            repository_overrides: vec![],
        };
        fs_err::create_dir_all(state::config_path().parent().expect("config parent"))
            .expect("create config dir");
        fs_err::write(
            state::config_path(),
            serde_json::to_vec_pretty(&state::DaemonRuntimeConfig {
                log_level: Some("debug".into()),
                task_board_git_runtime_config: Some(runtime_config.clone()),
            })
            .expect("encode legacy config"),
        )
        .expect("write legacy config");
        let digest = state::task_board_git_runtime_secret_handoff_digest(&runtime_config)
            .expect("digest legacy secrets")
            .expect("plaintext digest");

        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(async {
                let db = AsyncDaemonDb::connect(&tmp.path().join("harness.db"))
                    .await
                    .expect("open db");
                db.initialize_empty_task_board(
                    &runtime_config.without_secret_metadata(),
                    Some(&digest),
                )
                .await
                .expect("initialize task board");

                let prepared = super::prepare_task_board_git_runtime_secret_handoff(&db)
                    .await
                    .expect("prepare handoff");
                assert!(prepared.prepared);
                assert_eq!(prepared.digest.as_deref(), Some(digest.as_str()));
                assert_eq!(
                    prepared.runtime.global.ssh_private_key.as_deref(),
                    Some("legacy-secret")
                );
                assert!(
                    fs_err::read_to_string(state::config_path())
                        .expect("read prepared config")
                        .contains("legacy-secret"),
                    "prepare must not strip the legacy payload"
                );

                let request = TaskBoardGitRuntimeSecretHandoffAckRequest {
                    migration_id: prepared.migration_id.expect("migration id"),
                    digest,
                };
                let acknowledged =
                    super::acknowledge_task_board_git_runtime_secret_handoff(&db, &request)
                        .await
                        .expect("acknowledge handoff");
                assert!(acknowledged.acknowledged);
                assert!(
                    state::load_runtime_config_raw()
                        .expect("load post-ack config")
                        .expect("config remains for log level")
                        .task_board_git_runtime_config
                        .is_none()
                );
                let marker = db
                    .task_board_import_marker("empty_database")
                    .await
                    .expect("load import marker")
                    .expect("import marker");
                assert_eq!(marker.secret_handoff_phase, "complete");

                assert!(
                    super::acknowledge_task_board_git_runtime_secret_handoff(&db, &request)
                        .await
                        .expect("repeat acknowledgement")
                        .acknowledged
                );
            });
    });
}

#[test]
fn secret_handoff_ack_recovers_after_legacy_envelope_was_removed() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let runtime_config = TaskBoardGitRuntimeConfig {
            global: TaskBoardGitRuntimeProfile {
                ssh_private_key: Some("legacy-secret".into()),
                ..Default::default()
            },
            repository_overrides: vec![],
        };
        fs_err::create_dir_all(state::config_path().parent().expect("config parent"))
            .expect("create config dir");
        fs_err::write(
            state::config_path(),
            serde_json::to_vec_pretty(&state::DaemonRuntimeConfig {
                log_level: Some("debug".into()),
                task_board_git_runtime_config: Some(runtime_config.clone()),
            })
            .expect("encode legacy config"),
        )
        .expect("write legacy config");
        let digest = state::task_board_git_runtime_secret_handoff_digest(&runtime_config)
            .expect("digest legacy secrets")
            .expect("plaintext digest");

        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(async {
                let db = AsyncDaemonDb::connect(&tmp.path().join("harness.db"))
                    .await
                    .expect("open db");
                db.initialize_empty_task_board(
                    &runtime_config.without_secret_metadata(),
                    Some(&digest),
                )
                .await
                .expect("initialize task board");
                let marker = db
                    .pending_task_board_secret_handoff()
                    .await
                    .expect("pending marker")
                    .expect("handoff marker");
                let migration_id = marker.secret_handoff_id.expect("migration id");
                db.acknowledge_task_board_secret_handoff(&migration_id, &digest)
                    .await
                    .expect("persist acknowledging phase");
                state::remove_migrated_task_board_config_after_ack(&digest)
                    .expect("remove legacy envelope");

                let response = super::acknowledge_task_board_git_runtime_secret_handoff(
                    &db,
                    &TaskBoardGitRuntimeSecretHandoffAckRequest {
                        migration_id,
                        digest,
                    },
                )
                .await
                .expect("recover acknowledgement");
                assert!(response.acknowledged);
                assert!(
                    db.pending_task_board_secret_handoff()
                        .await
                        .expect("pending marker after recovery")
                        .is_none()
                );
            });
    });
}

#[cfg(unix)]
#[test]
fn runtime_config_persist_failure_keeps_in_memory_secrets() {
    use std::fs::Permissions;
    use std::os::unix::fs::PermissionsExt;

    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        update_task_board_git_runtime_config(&TaskBoardGitRuntimeConfig {
            global: TaskBoardGitRuntimeProfile {
                ssh_private_key: Some("initial-secret".into()),
                ..Default::default()
            },
            repository_overrides: vec![],
        })
        .expect("seed runtime config");

        let baseline = super::git_runtime_profile_for_repository(None)
            .expect("baseline profile")
            .ssh_private_key
            .expect("baseline secret stored");
        assert_eq!(baseline, "initial-secret");

        let daemon_root = state::config_path()
            .parent()
            .expect("daemon root parent")
            .to_path_buf();
        let original = daemon_root
            .metadata()
            .expect("daemon root metadata")
            .permissions();
        fs_err::set_permissions(&daemon_root, Permissions::from_mode(0o500))
            .expect("lock daemon root");

        let outcome = update_task_board_git_runtime_config(&TaskBoardGitRuntimeConfig {
            global: TaskBoardGitRuntimeProfile {
                ssh_private_key: Some("rotated-secret".into()),
                ..Default::default()
            },
            repository_overrides: vec![],
        });
        fs_err::set_permissions(&daemon_root, original).expect("restore daemon root");

        assert!(
            outcome.is_err(),
            "persist should fail when path is read-only"
        );
        let after = super::git_runtime_profile_for_repository(None)
            .expect("post-failure profile")
            .ssh_private_key
            .expect("in-memory secret unchanged");
        assert_eq!(
            after, "initial-secret",
            "in-memory secret must stay stale when persist fails",
        );
    });
}

#[test]
fn external_sync_config_keeps_todoist_env_precedence() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let _ = super::sync_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest::default());
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
        let _ = super::sync_task_board_todoist_token(&TaskBoardTodoistTokenSyncRequest::default());
    });
}
