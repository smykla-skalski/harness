use super::{
    TaskBoardGitRepositoryOverride, TaskBoardGitRuntimeConfig, TaskBoardGitRuntimeProfile,
    TaskBoardGitSigningConfig, TaskBoardGitSigningMode, normalize_repository_slug,
};

#[test]
fn normalize_repository_slug_rejects_invalid_values() {
    assert_eq!(
        normalize_repository_slug(Some(" owner/repo ")),
        Some("owner/repo".into())
    );
    assert_eq!(normalize_repository_slug(Some("owner/repo/extra")), None);
    assert_eq!(normalize_repository_slug(Some("owner")), None);
    assert_eq!(normalize_repository_slug(Some(" ")), None);
}

#[test]
fn resolved_profile_merges_repository_override() {
    let config = TaskBoardGitRuntimeConfig {
        global: TaskBoardGitRuntimeProfile {
            author_name: Some("Global User".into()),
            author_email: Some("global@example.com".into()),
            ssh_key_path: Some("/tmp/global".into()),
            ssh_private_key: Some("global-ssh-private-key".into()),
            ssh_private_key_passphrase: Some("global-ssh-passphrase".into()),
            signing: TaskBoardGitSigningConfig {
                mode: TaskBoardGitSigningMode::Gpg,
                ssh_key_path: None,
                ssh_private_key: None,
                ssh_private_key_passphrase: None,
                gpg_key_id: Some("GLOBAL".into()),
                gpg_private_key_path: Some("/tmp/global-gpg.asc".into()),
                gpg_private_key: Some("global-gpg-private-key".into()),
                gpg_private_key_passphrase: Some("global-passphrase".into()),
                ..Default::default()
            },
            ..Default::default()
        },
        repository_overrides: vec![TaskBoardGitRepositoryOverride {
            repository: "owner/repo".into(),
            profile: TaskBoardGitRuntimeProfile {
                author_name: None,
                author_email: Some("repo@example.com".into()),
                ssh_key_path: Some("/tmp/repo".into()),
                ssh_private_key: None,
                ssh_private_key_passphrase: None,
                signing: TaskBoardGitSigningConfig {
                    mode: TaskBoardGitSigningMode::Ssh,
                    ssh_key_path: Some("/tmp/sign".into()),
                    ssh_private_key: Some("repo-signing-key".into()),
                    ssh_private_key_passphrase: Some("repo-signing-passphrase".into()),
                    gpg_key_id: None,
                    gpg_private_key_path: None,
                    gpg_private_key: None,
                    gpg_private_key_passphrase: None,
                    ..Default::default()
                },
                ..Default::default()
            },
        }],
    };

    let resolved = config.resolved_profile(Some("OWNER/REPO"));
    assert_eq!(resolved.author_name.as_deref(), Some("Global User"));
    assert_eq!(resolved.author_email.as_deref(), Some("repo@example.com"));
    assert_eq!(resolved.ssh_key_path.as_deref(), Some("/tmp/repo"));
    assert_eq!(
        resolved.ssh_private_key.as_deref(),
        Some("global-ssh-private-key")
    );
    assert_eq!(
        resolved.ssh_private_key_passphrase.as_deref(),
        Some("global-ssh-passphrase")
    );
    assert_eq!(resolved.signing.mode, TaskBoardGitSigningMode::Ssh);
    assert_eq!(resolved.signing.ssh_key_path.as_deref(), Some("/tmp/sign"));
    assert_eq!(
        resolved.signing.ssh_private_key.as_deref(),
        Some("repo-signing-key")
    );
    assert!(resolved.signing.gpg_key_id.is_none());
    assert!(resolved.signing.gpg_private_key_path.is_none());
    assert!(resolved.signing.gpg_private_key_passphrase.is_none());
}

#[test]
fn runtime_config_redacts_synced_private_key_material() {
    let config = TaskBoardGitRuntimeConfig {
        global: TaskBoardGitRuntimeProfile {
            ssh_private_key: Some("ssh-secret".into()),
            ssh_private_key_passphrase: Some("ssh-passphrase".into()),
            signing: TaskBoardGitSigningConfig {
                mode: TaskBoardGitSigningMode::Gpg,
                ssh_private_key: Some("signing-ssh-secret".into()),
                ssh_private_key_passphrase: Some("signing-ssh-passphrase".into()),
                gpg_private_key: Some("gpg-secret".into()),
                gpg_private_key_passphrase: Some("gpg-passphrase".into()),
                ..Default::default()
            },
            ..Default::default()
        },
        repository_overrides: vec![],
    };

    let serialized =
        serde_json::to_string(&config.without_secrets()).expect("serialize redacted config");

    assert!(!serialized.contains("ssh-secret"));
    assert!(!serialized.contains("ssh-passphrase"));
    assert!(!serialized.contains("signing-ssh-secret"));
    assert!(!serialized.contains("gpg-secret"));
    assert!(!serialized.contains("gpg-passphrase"));
}
