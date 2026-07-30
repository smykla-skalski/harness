use std::env;
#[cfg(not(feature = "daemon-runtime"))]
use std::path::PathBuf;

pub use harness_hook::workspace::ensure_non_indexable;
#[cfg(target_os = "macos")]
pub use harness_hook::workspace::legacy_macos_root;
pub use harness_hook::workspace::{
    canonical_checkout_root, dirs_home, harness_data_root, project_context_dir, utc_now,
};

#[cfg(not(feature = "daemon-runtime"))]
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

// Only `agent_tui`'s `#[path]`-mirrored spawn helper calls these, and that
// mirrored copy exists solely under the default `bridge-runtime` build; the
// `daemon-runtime` build re-exports the real `harness-daemon` crate's own
// `agent_tui` instead, which resolves `crate::workspace::host_home_dir`
// against harness-daemon's own copy of this module, not this one.
#[cfg(not(feature = "daemon-runtime"))]
#[must_use]
pub(crate) fn host_home_dir() -> PathBuf {
    if let Some(value) = normalized_env_value(HARNESS_HOST_HOME_ENV) {
        return PathBuf::from(value);
    }
    account_home_dir()
        .or_else(|| normalized_env_value("HOME").map(PathBuf::from))
        .unwrap_or_else(dirs_home)
}

#[cfg(all(unix, not(feature = "daemon-runtime")))]
pub(crate) fn account_home_dir() -> Option<PathBuf> {
    use uzers::os::unix::UserExt as _;

    uzers::get_user_by_uid(uzers::get_current_uid()).map(|user| user.home_dir().to_path_buf())
}

#[cfg(all(not(unix), not(feature = "daemon-runtime")))]
pub(crate) fn account_home_dir() -> Option<PathBuf> {
    None
}
