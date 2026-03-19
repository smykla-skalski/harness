use std::env;
use std::path::{Path, PathBuf};

/// Prefix used for harness-owned resources (containers, networks, temp dirs).
pub const HARNESS_PREFIX: &str = "harness-";

/// Return current UTC time as ISO 8601 with Z suffix and no microseconds.
#[must_use]
pub fn utc_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

pub fn dirs_home() -> PathBuf {
    env::var("HOME").map_or_else(
        |_| env::temp_dir().join(format!("{HARNESS_PREFIX}{}", uzers::get_current_uid())),
        PathBuf::from,
    )
}

/// Harness data root: `data_root/harness`.
#[must_use]
pub fn harness_data_root() -> PathBuf {
    super::xdg::data_root().join("harness")
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
}
