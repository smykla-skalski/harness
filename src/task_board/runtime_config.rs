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

    /// Whether the value still contains plaintext private-key or passphrase
    /// bytes from the pre-Keychain persistence format.
    #[must_use]
    pub fn contains_plaintext_secrets(&self) -> bool {
        self.without_secrets() != *self
    }

    /// Whether the value contains either plaintext secret bytes or the old
    /// persisted `*_configured` metadata.
    #[must_use]
    pub fn contains_secret_metadata(&self) -> bool {
        self.without_secret_metadata() != *self
    }

    /// Strip both secret values and the wire-only `*_configured` indicators.
    ///
    /// Use this for disk persistence: the configured booleans are derived from
    /// the in-memory secret state at response time, so persisting them would
    /// leak metadata about secret presence onto disk and risk reporting stale
    /// "configured" state after a secret has been removed from RAM.
    #[must_use]
    pub fn without_secret_metadata(&self) -> Self {
        Self {
            global: self.global.without_secret_metadata(),
            repository_overrides: self
                .repository_overrides
                .iter()
                .map(TaskBoardGitRepositoryOverride::without_secret_metadata)
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_private_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_private_key_passphrase: Option<String>,
    /// Wire-only indicator that the daemon currently holds an SSH private key
    /// for this profile. Always reflects the secret presence at response time;
    /// inbound payloads may set it but it will be recomputed on the next GET.
    #[serde(default, skip_serializing_if = "is_false_ref")]
    pub ssh_private_key_configured: bool,
    /// Wire-only indicator that the daemon currently holds a passphrase for
    /// the SSH private key. See [`Self::ssh_private_key_configured`] for the
    /// inbound-payload caveat.
    #[serde(default, skip_serializing_if = "is_false_ref")]
    pub ssh_private_key_passphrase_configured: bool,
    #[serde(default)]
    pub signing: TaskBoardGitSigningConfig,
}

impl TaskBoardGitRuntimeProfile {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.author_name.is_none()
            && self.author_email.is_none()
            && self.ssh_key_path.is_none()
            && self.ssh_private_key.is_none()
            && self.ssh_private_key_passphrase.is_none()
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
        if override_profile.ssh_private_key.is_some() {
            self.ssh_private_key
                .clone_from(&override_profile.ssh_private_key);
        }
        if override_profile.ssh_private_key_passphrase.is_some() {
            self.ssh_private_key_passphrase
                .clone_from(&override_profile.ssh_private_key_passphrase);
        }
        if !override_profile.signing.is_empty() {
            self.signing.clone_from(&override_profile.signing);
        }
    }

    #[must_use]
    pub fn normalized(&self) -> Self {
        let ssh_private_key = normalize_optional_value(self.ssh_private_key.as_deref());
        let ssh_private_key_passphrase =
            normalize_optional_value(self.ssh_private_key_passphrase.as_deref());
        Self {
            author_name: normalize_optional_value(self.author_name.as_deref()),
            author_email: normalize_optional_value(self.author_email.as_deref()),
            ssh_key_path: normalize_optional_value(self.ssh_key_path.as_deref()),
            ssh_private_key_configured: ssh_private_key.is_some(),
            ssh_private_key_passphrase_configured: ssh_private_key_passphrase.is_some(),
            ssh_private_key,
            ssh_private_key_passphrase,
            signing: self.signing.normalized(),
        }
    }

    #[must_use]
    pub fn without_secrets(&self) -> Self {
        Self {
            author_name: self.author_name.clone(),
            author_email: self.author_email.clone(),
            ssh_key_path: self.ssh_key_path.clone(),
            ssh_private_key: None,
            ssh_private_key_passphrase: None,
            ssh_private_key_configured: self.ssh_private_key.is_some()
                || self.ssh_private_key_configured,
            ssh_private_key_passphrase_configured: self.ssh_private_key_passphrase.is_some()
                || self.ssh_private_key_passphrase_configured,
            signing: self.signing.without_secrets(),
        }
    }

    /// Strip both secret values and the wire-only `*_configured` indicators.
    /// See [`TaskBoardGitRuntimeConfig::without_secret_metadata`] for rationale.
    #[must_use]
    pub fn without_secret_metadata(&self) -> Self {
        Self {
            author_name: self.author_name.clone(),
            author_email: self.author_email.clone(),
            ssh_key_path: self.ssh_key_path.clone(),
            ssh_private_key: None,
            ssh_private_key_passphrase: None,
            ssh_private_key_configured: false,
            ssh_private_key_passphrase_configured: false,
            signing: self.signing.without_secret_metadata(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[expect(
    clippy::struct_excessive_bools,
    reason = "wire model exposes per-secret configured flags for multiple signing backends"
)]
pub struct TaskBoardGitSigningConfig {
    #[serde(default)]
    pub mode: TaskBoardGitSigningMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_key_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_private_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_private_key_passphrase: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpg_key_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpg_private_key_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpg_private_key: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gpg_private_key_passphrase: Option<String>,
    /// Wire-only indicator that the daemon currently holds the SSH signing
    /// private key. See [`TaskBoardGitRuntimeProfile::ssh_private_key_configured`]
    /// for the inbound-payload caveat.
    #[serde(default, skip_serializing_if = "is_false_ref")]
    pub ssh_private_key_configured: bool,
    #[serde(default, skip_serializing_if = "is_false_ref")]
    pub ssh_private_key_passphrase_configured: bool,
    #[serde(default, skip_serializing_if = "is_false_ref")]
    pub gpg_private_key_configured: bool,
    #[serde(default, skip_serializing_if = "is_false_ref")]
    pub gpg_private_key_passphrase_configured: bool,
}

impl TaskBoardGitSigningConfig {
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.mode == TaskBoardGitSigningMode::None
            && self.ssh_key_path.is_none()
            && self.ssh_private_key.is_none()
            && self.ssh_private_key_passphrase.is_none()
            && self.gpg_key_id.is_none()
            && self.gpg_private_key_path.is_none()
            && self.gpg_private_key.is_none()
            && self.gpg_private_key_passphrase.is_none()
    }

    #[must_use]
    pub fn normalized(&self) -> Self {
        let ssh_private_key = normalize_optional_value(self.ssh_private_key.as_deref());
        let ssh_private_key_passphrase =
            normalize_optional_value(self.ssh_private_key_passphrase.as_deref());
        let gpg_private_key = normalize_optional_value(self.gpg_private_key.as_deref());
        let gpg_private_key_passphrase =
            normalize_optional_value(self.gpg_private_key_passphrase.as_deref());
        Self {
            mode: self.mode,
            ssh_key_path: normalize_optional_value(self.ssh_key_path.as_deref()),
            ssh_private_key_configured: ssh_private_key.is_some(),
            ssh_private_key,
            ssh_private_key_passphrase_configured: ssh_private_key_passphrase.is_some(),
            ssh_private_key_passphrase,
            gpg_key_id: normalize_optional_value(self.gpg_key_id.as_deref()),
            gpg_private_key_path: normalize_optional_value(self.gpg_private_key_path.as_deref()),
            gpg_private_key_configured: gpg_private_key.is_some(),
            gpg_private_key,
            gpg_private_key_passphrase_configured: gpg_private_key_passphrase.is_some(),
            gpg_private_key_passphrase,
        }
    }

    #[must_use]
    pub fn without_secrets(&self) -> Self {
        Self {
            mode: self.mode,
            ssh_key_path: self.ssh_key_path.clone(),
            ssh_private_key: None,
            ssh_private_key_passphrase: None,
            gpg_key_id: self.gpg_key_id.clone(),
            gpg_private_key_path: self.gpg_private_key_path.clone(),
            gpg_private_key: None,
            gpg_private_key_passphrase: None,
            ssh_private_key_configured: self.ssh_private_key.is_some()
                || self.ssh_private_key_configured,
            ssh_private_key_passphrase_configured: self.ssh_private_key_passphrase.is_some()
                || self.ssh_private_key_passphrase_configured,
            gpg_private_key_configured: self.gpg_private_key.is_some()
                || self.gpg_private_key_configured,
            gpg_private_key_passphrase_configured: self.gpg_private_key_passphrase.is_some()
                || self.gpg_private_key_passphrase_configured,
        }
    }

    /// Strip both secret values and the wire-only `*_configured` indicators.
    /// See [`TaskBoardGitRuntimeConfig::without_secret_metadata`] for rationale.
    #[must_use]
    pub fn without_secret_metadata(&self) -> Self {
        Self {
            mode: self.mode,
            ssh_key_path: self.ssh_key_path.clone(),
            ssh_private_key: None,
            ssh_private_key_passphrase: None,
            gpg_key_id: self.gpg_key_id.clone(),
            gpg_private_key_path: self.gpg_private_key_path.clone(),
            gpg_private_key: None,
            gpg_private_key_passphrase: None,
            ssh_private_key_configured: false,
            ssh_private_key_passphrase_configured: false,
            gpg_private_key_configured: false,
            gpg_private_key_passphrase_configured: false,
        }
    }
}

#[expect(
    clippy::trivially_copy_pass_by_ref,
    reason = "serde skip_serializing_if requires a function taking `&T`"
)]
fn is_false_ref(value: &bool) -> bool {
    !*value
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

    /// Strip both secret values and the wire-only `*_configured` indicators.
    /// See [`TaskBoardGitRuntimeConfig::without_secret_metadata`] for rationale.
    #[must_use]
    pub fn without_secret_metadata(&self) -> Self {
        Self {
            repository: self.repository.clone(),
            profile: self.profile.without_secret_metadata(),
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

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TaskBoardTodoistTokenSyncRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardTodoistTokenSyncResponse {
    pub token_configured: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct TaskBoardOpenRouterTokenSyncRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TaskBoardOpenRouterTokenSyncResponse {
    pub token_configured: bool,
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
mod tests;
