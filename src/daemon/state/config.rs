use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{LazyLock, RwLock};

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::read_json_typed;
use crate::task_board::{
    TaskBoardGitHubRepositoryToken, TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitHubTokensSyncResponse, TaskBoardGitRuntimeConfig, TaskBoardGitRuntimeProfile,
    TaskBoardOpenRouterTokenSyncRequest, TaskBoardOpenRouterTokenSyncResponse,
    TaskBoardTodoistTokenSyncRequest, TaskBoardTodoistTokenSyncResponse, normalize_repository_slug,
};

use super::{append_event_best_effort, config_path, ensure_daemon_dirs};

pub const VALID_LOG_LEVELS: &[&str] = &["trace", "debug", "info", "warn", "error"];

static TASK_BOARD_GITHUB_TOKENS: LazyLock<RwLock<BTreeMap<PathBuf, TaskBoardGitHubTokenState>>> =
    LazyLock::new(|| RwLock::new(BTreeMap::new()));
static TASK_BOARD_TODOIST_TOKENS: LazyLock<RwLock<BTreeMap<PathBuf, String>>> =
    LazyLock::new(|| RwLock::new(BTreeMap::new()));
static TASK_BOARD_OPENROUTER_TOKENS: LazyLock<RwLock<BTreeMap<PathBuf, String>>> =
    LazyLock::new(|| RwLock::new(BTreeMap::new()));
static TASK_BOARD_GIT_RUNTIME_SECRETS: LazyLock<
    RwLock<BTreeMap<PathBuf, TaskBoardGitRuntimeConfig>>,
> = LazyLock::new(|| RwLock::new(BTreeMap::new()));

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct DaemonRuntimeConfig {
    #[serde(default)]
    pub log_level: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task_board_git_runtime_config: Option<TaskBoardGitRuntimeConfig>,
}

impl DaemonRuntimeConfig {
    /// Strip both secret values and the wire-only `*_configured` indicators
    /// from the embedded task-board git runtime config. Used on the load path
    /// so the daemon never trusts stale secret-presence metadata read off
    /// disk; the in-memory secret state alone drives the configured flags.
    fn without_secret_metadata(mut self) -> Self {
        self.task_board_git_runtime_config = self
            .task_board_git_runtime_config
            .map(|config| config.without_secret_metadata());
        self
    }
}

/// Load the persisted daemon runtime config, if present.
///
/// Strips both secret values and the wire-only `*_configured` indicators so
/// callers never observe disk-side secret material or stale secret-presence
/// metadata. Live secret presence is overlaid from the in-memory secret state
/// by [`load_task_board_git_runtime_config`].
///
/// # Errors
/// Returns `CliError` when the config file exists but cannot be parsed.
pub fn load_runtime_config() -> Result<Option<DaemonRuntimeConfig>, CliError> {
    if !config_path().is_file() {
        return Ok(None);
    }
    read_json_typed::<DaemonRuntimeConfig>(&config_path())
        .map(DaemonRuntimeConfig::without_secret_metadata)
        .map(Some)
}

/// Load the persisted daemon runtime config without stripping a pending
/// Task Board secret-migration envelope.
///
/// This is restricted to the one-time migration and config-preserving write
/// paths. Runtime consumers must continue to use [`load_runtime_config`].
pub(crate) fn load_runtime_config_raw() -> Result<Option<DaemonRuntimeConfig>, CliError> {
    if !config_path().is_file() {
        return Ok(None);
    }
    read_json_typed::<DaemonRuntimeConfig>(&config_path()).map(Some)
}

/// Return the persisted daemon log level, normalized for runtime use.
///
/// # Errors
/// Returns `CliError` when the runtime config exists but cannot be parsed or
/// contains an invalid log level.
pub fn load_persisted_log_level() -> Result<Option<String>, CliError> {
    load_runtime_config()?.map_or(Ok(None), |config| {
        normalize_optional_log_level(config.log_level.as_deref())
    })
}

/// Persist the daemon log level so future daemon restarts reuse it.
///
/// # Errors
/// Returns `CliError` when the runtime config cannot be written or the supplied
/// level is invalid.
pub fn persist_log_level(level: Option<&str>) -> Result<(), CliError> {
    let normalized = normalize_optional_log_level(level)?;
    ensure_daemon_dirs()?;
    super::config_migration::with_runtime_config_lock(|| {
        let mut config = load_runtime_config_for_persist();
        config.log_level = normalized;
        super::config_migration::write_runtime_config_durable(&config)
    })
}

/// Load the persisted task-board git runtime config, defaulting when absent.
///
/// # Errors
/// Returns `CliError` when the daemon runtime config exists but cannot be parsed.
#[cfg(test)]
pub fn load_task_board_git_runtime_config() -> Result<TaskBoardGitRuntimeConfig, CliError> {
    let mut config = load_runtime_config()?
        .and_then(|config| config.task_board_git_runtime_config)
        .map(|config| config.without_secret_metadata())
        .unwrap_or_default();
    overlay_task_board_git_runtime_secret_flags(&mut config);
    Ok(config)
}

pub(crate) fn overlay_task_board_git_runtime_secret_flags(config: &mut TaskBoardGitRuntimeConfig) {
    let secrets = TASK_BOARD_GIT_RUNTIME_SECRETS
        .read()
        .expect("task-board git runtime secret state lock poisoned")
        .get(&task_board_memory_key())
        .cloned()
        .unwrap_or_default();
    overlay_profile_flags(&mut config.global, &secrets.global);
    for override_config in &mut config.repository_overrides {
        let secret_profile = secrets.resolved_profile(Some(&override_config.repository));
        overlay_profile_flags(&mut override_config.profile, &secret_profile);
    }
}

pub(crate) fn overlay_task_board_git_runtime_profile_secrets(
    profile: &mut TaskBoardGitRuntimeProfile,
    repository: Option<&str>,
) {
    let secrets = TASK_BOARD_GIT_RUNTIME_SECRETS
        .read()
        .expect("task-board git runtime secret state lock poisoned")
        .get(&task_board_memory_key())
        .cloned()
        .unwrap_or_default()
        .resolved_profile(repository);
    profile.ssh_private_key = secrets.ssh_private_key;
    profile.ssh_private_key_passphrase = secrets.ssh_private_key_passphrase;
    profile.signing.ssh_private_key = secrets.signing.ssh_private_key;
    profile.signing.ssh_private_key_passphrase = secrets.signing.ssh_private_key_passphrase;
    profile.signing.gpg_private_key = secrets.signing.gpg_private_key;
    profile.signing.gpg_private_key_passphrase = secrets.signing.gpg_private_key_passphrase;
}

/// Materialize process-only key material into a database-loaded runtime config.
/// The returned value must remain in memory and must never be persisted.
pub(crate) fn overlay_task_board_git_runtime_secrets(config: &mut TaskBoardGitRuntimeConfig) {
    overlay_task_board_git_runtime_profile_secrets(&mut config.global, None);
    for override_config in &mut config.repository_overrides {
        overlay_task_board_git_runtime_profile_secrets(
            &mut override_config.profile,
            Some(&override_config.repository),
        );
    }
}

fn overlay_profile_flags(
    target: &mut TaskBoardGitRuntimeProfile,
    secrets: &TaskBoardGitRuntimeProfile,
) {
    target.ssh_private_key_configured |= secrets.ssh_private_key.is_some();
    target.ssh_private_key_passphrase_configured |= secrets.ssh_private_key_passphrase.is_some();
    target.signing.ssh_private_key_configured |= secrets.signing.ssh_private_key.is_some();
    target.signing.ssh_private_key_passphrase_configured |=
        secrets.signing.ssh_private_key_passphrase.is_some();
    target.signing.gpg_private_key_configured |= secrets.signing.gpg_private_key.is_some();
    target.signing.gpg_private_key_passphrase_configured |=
        secrets.signing.gpg_private_key_passphrase.is_some();
}

/// Persist the task-board git runtime config inside the daemon runtime config file.
///
/// Strips both secret values and the wire-only `*_configured` indicators so
/// neither secret material nor secret-presence metadata ever reaches the disk.
///
/// # Errors
/// Returns `CliError` when the runtime config cannot be written.
#[cfg(test)]
pub fn persist_task_board_git_runtime_config(
    task_board_config: &TaskBoardGitRuntimeConfig,
) -> Result<(), CliError> {
    ensure_daemon_dirs()?;
    super::config_migration::with_runtime_config_lock(|| {
        let mut config = load_runtime_config_for_persist();
        let task_board_config = task_board_config.without_secret_metadata();
        config.task_board_git_runtime_config =
            (!task_board_config.is_empty()).then_some(task_board_config);
        super::config_migration::write_runtime_config_durable(&config)
    })
}

/// Replace the daemon's in-memory task-board Git runtime secrets snapshot.
///
/// # Panics
/// Panics when the in-memory secret state lock is poisoned.
pub fn replace_task_board_git_runtime_secrets(task_board_config: &TaskBoardGitRuntimeConfig) {
    let mut state = TASK_BOARD_GIT_RUNTIME_SECRETS
        .write()
        .expect("task-board git runtime secret state lock poisoned");
    state.insert(task_board_memory_key(), task_board_config.clone());
}

/// Preserve process-only secret bytes when a redacted GET response is sent
/// back as a full runtime-config update. A false configured flag remains an
/// explicit removal.
#[must_use]
pub(crate) fn retaining_task_board_git_runtime_secrets(
    request: &TaskBoardGitRuntimeConfig,
) -> TaskBoardGitRuntimeConfig {
    let current = TASK_BOARD_GIT_RUNTIME_SECRETS
        .read()
        .expect("task-board git runtime secret state lock poisoned")
        .get(&task_board_memory_key())
        .cloned()
        .unwrap_or_default();
    let mut merged = request.clone();
    retain_profile_secrets(&mut merged.global, &current.global);
    for override_config in &mut merged.repository_overrides {
        let existing = current
            .repository_overrides
            .iter()
            .find(|candidate| candidate.repository == override_config.repository)
            .map(|candidate| &candidate.profile)
            .cloned()
            .unwrap_or_default();
        retain_profile_secrets(&mut override_config.profile, &existing);
    }
    merged
}

fn retain_profile_secrets(
    target: &mut TaskBoardGitRuntimeProfile,
    existing: &TaskBoardGitRuntimeProfile,
) {
    retain_secret(
        &mut target.ssh_private_key,
        target.ssh_private_key_configured,
        existing.ssh_private_key.as_ref(),
    );
    retain_secret(
        &mut target.ssh_private_key_passphrase,
        target.ssh_private_key_passphrase_configured,
        existing.ssh_private_key_passphrase.as_ref(),
    );
    retain_secret(
        &mut target.signing.ssh_private_key,
        target.signing.ssh_private_key_configured,
        existing.signing.ssh_private_key.as_ref(),
    );
    retain_secret(
        &mut target.signing.ssh_private_key_passphrase,
        target.signing.ssh_private_key_passphrase_configured,
        existing.signing.ssh_private_key_passphrase.as_ref(),
    );
    retain_secret(
        &mut target.signing.gpg_private_key,
        target.signing.gpg_private_key_configured,
        existing.signing.gpg_private_key.as_ref(),
    );
    retain_secret(
        &mut target.signing.gpg_private_key_passphrase,
        target.signing.gpg_private_key_passphrase_configured,
        existing.signing.gpg_private_key_passphrase.as_ref(),
    );
}

fn retain_secret(target: &mut Option<String>, configured: bool, existing: Option<&String>) {
    if target.is_none() && configured {
        *target = existing.cloned();
    }
}

/// Resolve a task-board Git runtime profile with current process-only secrets.
///
/// # Errors
/// Returns `CliError` when the daemon runtime config exists but cannot be parsed.
///
/// # Panics
/// Panics when the in-memory secret state lock is poisoned.
#[cfg(test)]
pub fn task_board_git_runtime_profile(
    repository: Option<&str>,
) -> Result<TaskBoardGitRuntimeProfile, CliError> {
    let mut profile = load_task_board_git_runtime_config()?.resolved_profile(repository);
    overlay_task_board_git_runtime_profile_secrets(&mut profile, repository);
    Ok(profile)
}

/// Replace the daemon's in-memory GitHub token snapshot.
///
/// # Panics
/// Panics when the in-memory token state lock is poisoned.
#[must_use]
pub fn replace_task_board_github_tokens(
    request: &TaskBoardGitHubTokensSyncRequest,
) -> TaskBoardGitHubTokensSyncResponse {
    let mut states = TASK_BOARD_GITHUB_TOKENS
        .write()
        .expect("task-board github token state lock poisoned");
    let state = states.entry(task_board_memory_key()).or_default();
    state.global_token = normalize_optional_value(request.global_token.as_deref());
    state.repository_tokens = request
        .repository_tokens
        .iter()
        .filter_map(TaskBoardGitHubRepositoryToken::normalized)
        .map(|token| (token.repository, token.token))
        .collect();
    TaskBoardGitHubTokensSyncResponse {
        global_token_configured: state.global_token.is_some(),
        repository_token_count: state.repository_tokens.len(),
    }
}

/// # Panics
/// Panics when the in-memory token state lock is poisoned.
#[must_use]
pub fn task_board_github_token(repository: Option<&str>) -> Option<String> {
    let states = TASK_BOARD_GITHUB_TOKENS
        .read()
        .expect("task-board github token state lock poisoned");
    let state = states.get(&task_board_memory_key())?;
    normalize_repository_slug(repository)
        .and_then(|repository| state.repository_tokens.get(&repository).cloned())
        .or_else(|| state.global_token.clone())
}

/// # Panics
/// Panics when the in-memory token state lock is poisoned.
#[must_use]
pub fn task_board_github_repository_token(repository: &str) -> Option<String> {
    let states = TASK_BOARD_GITHUB_TOKENS
        .read()
        .expect("task-board github token state lock poisoned");
    let state = states.get(&task_board_memory_key())?;
    normalize_repository_slug(Some(repository))
        .and_then(|repository| state.repository_tokens.get(&repository).cloned())
}

/// Replace the daemon's in-memory Todoist token snapshot.
///
/// # Panics
/// Panics when the in-memory token state lock is poisoned.
#[must_use]
pub fn replace_task_board_todoist_token(
    request: &TaskBoardTodoistTokenSyncRequest,
) -> TaskBoardTodoistTokenSyncResponse {
    let mut states = TASK_BOARD_TODOIST_TOKENS
        .write()
        .expect("task-board todoist token state lock poisoned");
    let token = normalize_optional_value(request.token.as_deref());
    let token_configured = token.is_some();
    if let Some(token) = token {
        states.insert(task_board_memory_key(), token);
    } else {
        states.remove(&task_board_memory_key());
    }
    TaskBoardTodoistTokenSyncResponse { token_configured }
}

/// # Panics
/// Panics when the in-memory token state lock is poisoned.
#[must_use]
pub fn task_board_todoist_token() -> Option<String> {
    TASK_BOARD_TODOIST_TOKENS
        .read()
        .expect("task-board todoist token state lock poisoned")
        .get(&task_board_memory_key())
        .cloned()
}

/// Replace the daemon's in-memory `OpenRouter` token snapshot.
///
/// # Panics
/// Panics when the in-memory token state lock is poisoned.
#[must_use]
pub fn replace_task_board_openrouter_token(
    request: &TaskBoardOpenRouterTokenSyncRequest,
) -> TaskBoardOpenRouterTokenSyncResponse {
    let mut states = TASK_BOARD_OPENROUTER_TOKENS
        .write()
        .expect("task-board openrouter token state lock poisoned");
    let token = normalize_optional_value(request.token.as_deref());
    let token_configured = token.is_some();
    if let Some(token) = token {
        states.insert(task_board_memory_key(), token);
    } else {
        states.remove(&task_board_memory_key());
    }
    TaskBoardOpenRouterTokenSyncResponse { token_configured }
}

/// # Panics
/// Panics when the in-memory token state lock is poisoned.
#[must_use]
pub fn task_board_openrouter_token() -> Option<String> {
    TASK_BOARD_OPENROUTER_TOKENS
        .read()
        .expect("task-board openrouter token state lock poisoned")
        .get(&task_board_memory_key())
        .cloned()
}

fn task_board_memory_key() -> PathBuf {
    config_path()
}

/// Normalize and validate a daemon log level.
///
/// # Errors
/// Returns `CliError` when the supplied level is not one of the supported
/// daemon log levels.
pub fn parse_log_level(level: &str) -> Result<String, CliError> {
    let normalized = level.trim().to_ascii_lowercase();
    if VALID_LOG_LEVELS.contains(&normalized.as_str()) {
        return Ok(normalized);
    }

    Err(CliErrorKind::workflow_parse(format!(
        "invalid log level '{level}', expected one of: {}",
        VALID_LOG_LEVELS.join(", ")
    ))
    .into())
}

fn normalize_optional_log_level(level: Option<&str>) -> Result<Option<String>, CliError> {
    level
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(parse_log_level)
        .transpose()
}

fn load_runtime_config_for_persist() -> DaemonRuntimeConfig {
    match load_runtime_config_raw() {
        Ok(Some(config)) => config,
        Ok(None) => DaemonRuntimeConfig::default(),
        Err(error) => {
            append_event_best_effort(
                "warn",
                &format!(
                    "replacing invalid daemon runtime config {} before persisting daemon log level: {error}",
                    config_path().display()
                ),
            );
            DaemonRuntimeConfig::default()
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct TaskBoardGitHubTokenState {
    global_token: Option<String>,
    repository_tokens: BTreeMap<String, String>,
}

fn normalize_optional_value(value: Option<&str>) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}
