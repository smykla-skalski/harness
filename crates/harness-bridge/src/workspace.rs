use std::env;
use std::path::PathBuf;

pub use harness_hook::workspace::paths::ensure_non_indexable;
#[cfg(target_os = "macos")]
pub use harness_hook::workspace::paths::legacy_macos_root;
pub use harness_hook::workspace::{
    canonical_checkout_root, dirs_home, harness_data_root, project_context_dir, utc_now,
};

const HARNESS_HOST_HOME_ENV: &str = "HARNESS_HOST_HOME";

#[must_use]
pub(crate) fn normalized_env_value(name: &str) -> Option<String> {
    let value = env::var(name).unwrap_or_default();
    let value = value.trim();
    (!(value.is_empty()
        || value.eq_ignore_ascii_case("unset")
        || (value.starts_with("${") && value.ends_with('}'))))
    .then(|| value.to_string())
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
