use std::env;
use std::path::{Path, PathBuf};

/// Prefix used for harness-owned resources (containers, networks, temp dirs).
pub const HARNESS_PREFIX: &str = "harness-";
const HARNESS_HOST_HOME_ENV: &str = "HARNESS_HOST_HOME";

fn fallback_home_dir() -> PathBuf {
    env::temp_dir().join(format!("{HARNESS_PREFIX}{}", uzers::get_current_uid()))
}

/// Return current UTC time as ISO 8601 with Z suffix and no microseconds.
#[must_use]
pub fn utc_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

#[must_use]
pub fn dirs_home() -> PathBuf {
    user_dirs::home_dir().unwrap_or_else(|_| fallback_home_dir())
}

#[must_use]
pub(crate) fn host_home_dir() -> PathBuf {
    if let Some(value) = normalized_env_value(HARNESS_HOST_HOME_ENV) {
        return PathBuf::from(value);
    }
    account_home_dir()
        .or_else(|| normalized_env_value("HOME").map(PathBuf::from))
        .unwrap_or_else(dirs_home)
}

#[cfg(unix)]
fn account_home_dir() -> Option<PathBuf> {
    use uzers::os::unix::UserExt as _;

    uzers::get_user_by_uid(uzers::get_current_uid()).map(|user| user.home_dir().to_path_buf())
}

#[cfg(not(unix))]
fn account_home_dir() -> Option<PathBuf> {
    None
}

#[must_use]
pub(crate) fn normalized_env_value(name: &str) -> Option<String> {
    let value = env::var(name).unwrap_or_default();
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with("${") && trimmed.ends_with('}') {
        return None;
    }
    if trimmed.eq_ignore_ascii_case("unset") {
        return None;
    }
    Some(trimmed.to_string())
}

/// Harness data root: `data_root/harness`.
#[must_use]
pub fn harness_data_root() -> PathBuf {
    super::session::data_root().join("harness")
}

/// Legacy macOS data root used before the App Sandbox migration.
///
/// Returns `~/Library/Application Support/harness`.
#[cfg(target_os = "macos")]
#[must_use]
pub fn legacy_macos_root() -> PathBuf {
    host_home_dir()
        .join("Library")
        .join("Application Support")
        .join("harness")
}

/// Shorten an absolute path for human-readable terminal output.
///
/// Paths under the harness data root become `~harness/<rest>`.
/// Other paths under `$HOME` get the home prefix replaced with `~`.
/// Everything else is returned unchanged.
#[must_use]
pub fn shorten_path(path: &Path) -> String {
    let hdr = harness_data_root();
    if let Ok(rel) = path.strip_prefix(&hdr) {
        return format!("~harness/{}", rel.display());
    }
    let home = dirs_home();
    if let Ok(rel) = path.strip_prefix(&home) {
        return format!("~/{}", rel.display());
    }
    path.display().to_string()
}

#[cfg(test)]
mod tests;
