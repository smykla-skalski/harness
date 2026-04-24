use std::path::PathBuf;

use crate::errors::{CliError, CliErrorKind};
use crate::workspace::{
    dirs_home, ensure_non_indexable, harness_data_root, host_home_dir, normalized_env_value,
};

use super::{
    APP_GROUP_ID_ENV, CURRENT_LAUNCH_AGENT_PLIST, DAEMON_DATA_HOME_ENV, DAEMON_LOCK_FILE,
    DAEMON_ROOT_OVERRIDE, LAUNCH_AGENTS_DIR, LEGACY_LAUNCH_AGENT_PLIST, MANIFEST_LOCK_FILE,
};

/// Install a process-local override so every subsequent [`daemon_root`] call
/// returns `path`. Passing `None` clears the override.
///
/// # Panics
/// Panics only if the internal mutex is poisoned, which indicates another
/// thread panicked while holding the override lock.
pub fn set_daemon_root_override(path: Option<PathBuf>) {
    *DAEMON_ROOT_OVERRIDE
        .lock()
        .expect("daemon root override mutex poisoned") = path;
}

#[must_use]
fn daemon_root_override() -> Option<PathBuf> {
    DAEMON_ROOT_OVERRIDE
        .lock()
        .expect("daemon root override mutex poisoned")
        .clone()
}

#[must_use]
pub fn daemon_root() -> PathBuf {
    if let Some(override_root) = daemon_root_override() {
        return override_root;
    }
    default_daemon_root()
}

#[must_use]
pub fn default_daemon_root() -> PathBuf {
    if let Some(value) = normalized_env_value(DAEMON_DATA_HOME_ENV) {
        return PathBuf::from(value).join("harness").join("daemon");
    }
    if let Some(value) = normalized_env_value(APP_GROUP_ID_ENV) {
        return host_home_dir()
            .join("Library")
            .join("Group Containers")
            .join(value)
            .join("harness")
            .join("daemon");
    }
    harness_data_root().join("daemon")
}

#[must_use]
pub fn manifest_path() -> PathBuf {
    daemon_root().join("manifest.json")
}

#[must_use]
pub(super) fn manifest_lock_path() -> PathBuf {
    daemon_root().join(MANIFEST_LOCK_FILE)
}

#[must_use]
pub fn auth_token_path() -> PathBuf {
    daemon_root().join("auth-token")
}

#[must_use]
pub fn events_path() -> PathBuf {
    daemon_root().join("events.jsonl")
}

#[must_use]
pub fn launch_agent_path() -> PathBuf {
    launch_agents_dir().join(CURRENT_LAUNCH_AGENT_PLIST)
}

#[must_use]
pub fn legacy_launch_agent_path() -> PathBuf {
    launch_agents_dir().join(LEGACY_LAUNCH_AGENT_PLIST)
}

#[must_use]
pub fn lock_path() -> PathBuf {
    daemon_root().join(DAEMON_LOCK_FILE)
}

fn launch_agents_dir() -> PathBuf {
    dirs_home().join("Library").join(LAUNCH_AGENTS_DIR)
}

/// Ensure the daemon directory structure exists.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn ensure_daemon_dirs() -> Result<(), CliError> {
    fs_err::create_dir_all(daemon_root())
        .map_err(|error| CliErrorKind::workflow_io(format!("create daemon root: {error}")))?;
    ensure_non_indexable(&harness_data_root()).map_err(|error| {
        CliErrorKind::workflow_io(format!("mark harness data root non-indexable: {error}"))
    })?;
    Ok(())
}
