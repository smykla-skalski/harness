use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TaskBoardGitRuntimeConfig {
    #[serde(default)]
    pub global: TaskBoardGitRuntimeProfile,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repository_overrides: Vec<TaskBoardGitRepositoryOverride>,
}

impl TaskBoardGitRuntimeConfig {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.global.is_empty() && self.repository_overrides.is_empty()
    }

    #[must_use]
    pub fn resolved_profile(&self, repository: Option<&str>) -> TaskBoardGitRuntimeProfile {
        let Some(repository) = normalize_repository_slug(repository) else {
            return self.global.clone();
        };
        let mut profile = self.global.clone();
        if let Some(override_profile) = self
            .repository_overrides
            .iter()
            .find(|override_config| override_config.repository == repository)
        {
            profile.apply_override(&override_profile.profile);
        }
        profile
    }

    #[must_use]
    pub fn without_secrets(&self) -> Self {
        Self {
            global: self.global.without_secrets(),
            repository_overrides: self
                .repository_overrides
                .iter()
                .map(TaskBoardGitRepositoryOverride::without_secrets)
                .collect(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TaskBoardGitRuntimeProfile {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub author_email: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_key_path: Option<String>,
    #[serde(default)]
    pub signing: TaskBoardGitSigningConfig,
}

impl TaskBoardGitRuntimeProfile {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.author_name.is_none()
            && self.author_email.is_none()
            && self.ssh_key_path.is_none()
            && self.signing.is_empty()
    }

    pub fn apply_override(&mut self, override_profile: &Self) {
        if override_profile.author_name.is_some() {
            self.author_name.clone_from(&override_profile.author_name);
        }
        if override_profile.author_email.is_some() {
            self.author_email.clone_from(&override_profile.author_email);
        }
        if override_profile.ssh_key_path.is_some() {
            self.ssh_key_path.clone_from(&override_profile.ssh_key_path);
        }
        if !override_profile.signing.is_empty() {
            self.signing.clone_from(&override_profile.signing);
        }
    }

    #[must_use]
    pub fn normalized(&self) -> Self {
        Self {
            author_name: normalize_optional_value(self.author_name.as_deref()),
            author_email: normalize_optional_value(self.author_email.as_deref()),
            ssh_key_path: normalize_optional_value(self.ssh_key_path.as_deref()),
            signing: self.signing.normalized(),
        }
    }

    #[must_use]
    pub fn without_secrets(&self) -> Self {
        Self {
            author_name: self.author_name.clone(),
            author_email: self.author_email.clone(),
            ssh_key_path: self.ssh_key_path.clone(),
            signing: self.signing.without_secrets(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TaskBoardGitSigningConfig {
    #[serde(default)]
    pub mode: TaskBoardGitSigningMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_key_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpg_key_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpg_private_key_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpg_private_key_passphrase: Option<String>,
}

impl TaskBoardGitSigningConfig {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.mode == TaskBoardGitSigningMode::None
            && self.ssh_key_path.is_none()
            && self.gpg_key_id.is_none()
            && self.gpg_private_key_path.is_none()
            && self.gpg_private_key_passphrase.is_none()
    }

    #[must_use]
    pub fn normalized(&self) -> Self {
        Self {
            mode: self.mode,
            ssh_key_path: normalize_optional_value(self.ssh_key_path.as_deref()),
            gpg_key_id: normalize_optional_value(self.gpg_key_id.as_deref()),
            gpg_private_key_path: normalize_optional_value(self.gpg_private_key_path.as_deref()),
            gpg_private_key_passphrase: normalize_optional_value(
                self.gpg_private_key_passphrase.as_deref(),
            ),
        }
    }

    #[must_use]
    pub fn without_secrets(&self) -> Self {
        Self {
            mode: self.mode,
            ssh_key_path: self.ssh_key_path.clone(),
            gpg_key_id: self.gpg_key_id.clone(),
            gpg_private_key_path: self.gpg_private_key_path.clone(),
            gpg_private_key_passphrase: None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum TaskBoardGitSigningMode {
    #[default]
    None,
    Ssh,
    Gpg,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardGitRepositoryOverride {
    pub repository: String,
    #[serde(default)]
    pub profile: TaskBoardGitRuntimeProfile,
}

impl TaskBoardGitRepositoryOverride {
    #[must_use]
    pub fn normalized(&self) -> Option<Self> {
        let repository = normalize_repository_slug(Some(self.repository.as_str()))?;
        Some(Self {
            repository,
            profile: self.profile.normalized(),
        })
    }

    #[must_use]
    pub fn without_secrets(&self) -> Self {
        Self {
            repository: self.repository.clone(),
            profile: self.profile.without_secrets(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TaskBoardGitHubTokensSyncRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub global_token: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub repository_tokens: Vec<TaskBoardGitHubRepositoryToken>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardGitHubRepositoryToken {
    pub repository: String,
    pub token: String,
}

impl TaskBoardGitHubRepositoryToken {
    #[must_use]
    pub fn normalized(&self) -> Option<Self> {
        let repository = normalize_repository_slug(Some(self.repository.as_str()))?;
        let token = normalize_optional_value(Some(self.token.as_str()))?;
        Some(Self { repository, token })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardGitHubTokensSyncResponse {
    pub global_token_configured: bool,
    pub repository_token_count: usize,
}

#[must_use]
pub fn normalize_repository_slug(repository: Option<&str>) -> Option<String> {
    let repository = normalize_optional_value(repository)?;
    let mut parts = repository.split('/');
    let owner = parts.next()?.trim();
    let repo = parts.next()?.trim();
    if owner.is_empty() || repo.is_empty() || parts.next().is_some() {
        return None;
    }
    Some(format!(
        "{}/{}",
        owner.to_ascii_lowercase(),
        repo.to_ascii_lowercase()
    ))
}

#[must_use]
pub fn normalize_optional_value(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

#[cfg(test)]
mod tests {
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
                signing: TaskBoardGitSigningConfig {
                    mode: TaskBoardGitSigningMode::Gpg,
                    ssh_key_path: None,
                    gpg_key_id: Some("GLOBAL".into()),
                    gpg_private_key_path: Some("/tmp/global-gpg.asc".into()),
                    gpg_private_key_passphrase: Some("global-passphrase".into()),
                },
            },
            repository_overrides: vec![TaskBoardGitRepositoryOverride {
                repository: "owner/repo".into(),
                profile: TaskBoardGitRuntimeProfile {
                    author_name: None,
                    author_email: Some("repo@example.com".into()),
                    ssh_key_path: Some("/tmp/repo".into()),
                    signing: TaskBoardGitSigningConfig {
                        mode: TaskBoardGitSigningMode::Ssh,
                        ssh_key_path: Some("/tmp/sign".into()),
                        gpg_key_id: None,
                        gpg_private_key_path: None,
                        gpg_private_key_passphrase: None,
                    },
                },
            }],
        };

        let resolved = config.resolved_profile(Some("OWNER/REPO"));
        assert_eq!(resolved.author_name.as_deref(), Some("Global User"));
        assert_eq!(resolved.author_email.as_deref(), Some("repo@example.com"));
        assert_eq!(resolved.ssh_key_path.as_deref(), Some("/tmp/repo"));
        assert_eq!(resolved.signing.mode, TaskBoardGitSigningMode::Ssh);
        assert_eq!(resolved.signing.ssh_key_path.as_deref(), Some("/tmp/sign"));
        assert!(resolved.signing.gpg_key_id.is_none());
        assert!(resolved.signing.gpg_private_key_path.is_none());
        assert!(resolved.signing.gpg_private_key_passphrase.is_none());
    }
}
