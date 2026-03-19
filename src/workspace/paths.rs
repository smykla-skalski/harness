use std::env;
use std::path::{Path, PathBuf};

/// Prefix used for harness-owned resources (containers, networks, temp dirs).
pub const HARNESS_PREFIX: &str = "harness-";

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

/// Harness data root: `data_root/harness`.
#[must_use]
pub fn harness_data_root() -> PathBuf {
    super::session::data_root().join("harness")
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
mod tests {
    use super::*;

    #[test]
    fn utc_now_ends_with_z() {
        let now = utc_now();
        assert!(now.ends_with('Z'), "expected Z suffix, got: {now}");
        assert!(!now.contains('+'), "expected no +, got: {now}");
    }

    #[test]
    fn dirs_home_prefers_home_env() {
        let tmp = tempfile::tempdir().unwrap();
        temp_env::with_var("HOME", Some(tmp.path()), || {
            assert_eq!(dirs_home(), tmp.path());
        });
    }
}
