use serde::{Deserialize, Serialize};

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty};

use super::{append_event_best_effort, config_path, ensure_daemon_dirs};

pub const VALID_LOG_LEVELS: &[&str] = &["trace", "debug", "info", "warn", "error"];

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct DaemonRuntimeConfig {
    #[serde(default)]
    pub log_level: Option<String>,
}

/// Load the persisted daemon runtime config, if present.
///
/// # Errors
/// Returns `CliError` when the config file exists but cannot be parsed.
pub fn load_runtime_config() -> Result<Option<DaemonRuntimeConfig>, CliError> {
    if !config_path().is_file() {
        return Ok(None);
    }
    read_json_typed(&config_path()).map(Some)
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
