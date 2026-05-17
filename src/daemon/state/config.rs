use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{LazyLock, RwLock};

use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::task_board::{
    TaskBoardGitHubRepositoryToken, TaskBoardGitHubTokensSyncRequest,
    TaskBoardGitHubTokensSyncResponse, TaskBoardGitRuntimeConfig, TaskBoardGitRuntimeProfile,
    TaskBoardTodoistTokenSyncRequest, TaskBoardTodoistTokenSyncResponse, normalize_repository_slug,
};

use super::{append_event_best_effort, config_path, ensure_daemon_dirs};

pub const VALID_LOG_LEVELS: &[&str] = &["trace", "debug", "info", "warn", "error"];

static TASK_BOARD_GITHUB_TOKENS: LazyLock<RwLock<BTreeMap<PathBuf, TaskBoardGitHubTokenState>>> =
    LazyLock::new(|| RwLock::new(BTreeMap::new()));
static TASK_BOARD_TODOIST_TOKENS: LazyLock<RwLock<BTreeMap<PathBuf, String>>> =
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
    fn without_secrets(mut self) -> Self {
        self.task_board_git_runtime_config = self
            .task_board_git_runtime_config
            .map(|config| config.without_secrets());
        self
    }
}

/// Load the persisted daemon runtime config, if present.
///
/// # Errors
/// Returns `CliError` when the config file exists but cannot be parsed.
pub fn load_runtime_config() -> Result<Option<DaemonRuntimeConfig>, CliError> {
    if !config_path().is_file() {
        return Ok(None);
    }
    read_json_typed::<DaemonRuntimeConfig>(&config_path())
        .map(DaemonRuntimeConfig::without_secrets)
        .map(Some)
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
    let mut config = load_runtime_config_for_persist();
    config.log_level = normalized;
    write_json_pretty(&config_path(), &config)
}

/// Load the persisted task-board git runtime config, defaulting when absent.
///
/// # Errors
/// Returns `CliError` when the daemon runtime config exists but cannot be parsed.
pub fn load_task_board_git_runtime_config() -> Result<TaskBoardGitRuntimeConfig, CliError> {
    let mut config = load_runtime_config()?
        .and_then(|config| config.task_board_git_runtime_config)
        .map(|config| config.without_secrets())
        .unwrap_or_default();
    overlay_runtime_secret_flags(&mut config);
    Ok(config)
}

fn overlay_runtime_secret_flags(config: &mut TaskBoardGitRuntimeConfig) {
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
/// # Errors
/// Returns `CliError` when the runtime config cannot be written.
pub fn persist_task_board_git_runtime_config(
    task_board_config: &TaskBoardGitRuntimeConfig,
) -> Result<(), CliError> {
    ensure_daemon_dirs()?;
    let mut config = load_runtime_config_for_persist();
    let task_board_config = task_board_config.without_secrets();
    config.task_board_git_runtime_config =
        (!task_board_config.is_empty()).then_some(task_board_config);
    write_json_pretty(&config_path(), &config)
}

/// One-shot migration drain: if the on-disk daemon runtime config still
/// contains plaintext task-board git secrets (from an older daemon), return
/// the full unstripped runtime config and persist a stripped version back to
/// disk. Returns `Ok(None)` when the on-disk config is already stripped.
///
/// # Errors
/// Returns `CliError` when the runtime config exists but cannot be parsed or
/// the stripped version cannot be written back.
pub fn drain_task_board_git_runtime_secrets() -> Result<Option<TaskBoardGitRuntimeConfig>, CliError>
{
    if !config_path().is_file() {
        return Ok(None);
    }
    let raw = read_json_typed::<DaemonRuntimeConfig>(&config_path())?;
    let Some(raw_task_board) = raw.task_board_git_runtime_config.clone() else {
        return Ok(None);
    };
    let stripped = raw_task_board.without_secrets();
    if stripped == raw_task_board {
        return Ok(None);
    }
    ensure_daemon_dirs()?;
    let mut on_disk = raw;
    on_disk.task_board_git_runtime_config = (!stripped.is_empty()).then_some(stripped);
    write_json_pretty(&config_path(), &on_disk)?;
    Ok(Some(raw_task_board))
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

/// Resolve a task-board Git runtime profile with current process-only secrets.
///
/// # Errors
/// Returns `CliError` when the daemon runtime config exists but cannot be parsed.
///
/// # Panics
/// Panics when the in-memory secret state lock is poisoned.
pub fn task_board_git_runtime_profile(
    repository: Option<&str>,
) -> Result<TaskBoardGitRuntimeProfile, CliError> {
    let mut profile = load_task_board_git_runtime_config()?.resolved_profile(repository);
    let secrets = TASK_BOARD_GIT_RUNTIME_SECRETS
        .read()
        .expect("task-board git runtime secret state lock poisoned")
        .get(&task_board_memory_key())
        .cloned()
        .unwrap_or_default();
    let secret_profile = secrets.resolved_profile(repository);
    profile.ssh_private_key = secret_profile.ssh_private_key;
    profile.ssh_private_key_passphrase = secret_profile.ssh_private_key_passphrase;
    profile.signing.ssh_private_key = secret_profile.signing.ssh_private_key;
    profile.signing.ssh_private_key_passphrase = secret_profile.signing.ssh_private_key_passphrase;
    profile.signing.gpg_private_key = secret_profile.signing.gpg_private_key;
    profile.signing.gpg_private_key_passphrase = secret_profile.signing.gpg_private_key_passphrase;
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
    match load_runtime_config() {
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
