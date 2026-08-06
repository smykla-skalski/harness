use std::env;

pub use harness_hook::workspace::ensure_non_indexable;
#[cfg(target_os = "macos")]
pub use harness_hook::workspace::legacy_macos_root;
pub use harness_hook::workspace::{
    canonical_checkout_root, dirs_home, harness_data_root, project_context_dir, utc_now,
};

#[must_use]
pub(crate) fn normalized_env_value(name: &str) -> Option<String> {
    let value = env::var(name).unwrap_or_default();
    let value = value.trim();
    (!(value.is_empty()
        || value.eq_ignore_ascii_case("unset")
        || (value.starts_with("${") && value.ends_with('}'))))
    .then(|| value.to_string())
}
