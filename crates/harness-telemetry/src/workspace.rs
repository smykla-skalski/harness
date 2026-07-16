use std::env;
use std::path::PathBuf;

#[must_use]
pub fn harness_data_root() -> PathBuf {
    data_root().join("harness")
}

#[must_use]
fn data_root() -> PathBuf {
    if let Some(value) = normalized_env_value("XDG_DATA_HOME") {
        return PathBuf::from(value);
    }
    #[cfg(target_os = "macos")]
    if let Some(group_id) = normalized_env_value("HARNESS_APP_GROUP_ID") {
        let group_root = home_dir()
            .join("Library")
            .join("Group Containers")
            .join(group_id);
        return if group_root.exists() {
            group_root
        } else {
            home_dir().join("Library").join("Application Support")
        };
    }
    user_dirs::data_dir().unwrap_or_else(|_| home_dir().join(".local").join("share"))
}

fn home_dir() -> PathBuf {
    normalized_env_value("HARNESS_HOST_HOME")
        .map(PathBuf::from)
        .or_else(|| user_dirs::home_dir().ok())
        .or_else(|| normalized_env_value("HOME").map(PathBuf::from))
        .unwrap_or_else(env::temp_dir)
}

#[must_use]
pub fn normalized_env_value(name: &str) -> Option<String> {
    let value = env::var(name).ok()?;
    let value = value.trim();
    if value.is_empty()
        || value.eq_ignore_ascii_case("unset")
        || value.starts_with("${") && value.ends_with('}')
    {
        return None;
    }
    Some(value.to_string())
}
