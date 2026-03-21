use std::collections::HashMap;
use std::env;
use std::path::Path;

use crate::infra::blocks::kuma::cli::primary_kumactl_dir;

/// Merge current env with extra key-value pairs.
#[must_use]
pub fn merge_env<'a, I>(extra: I) -> HashMap<String, String>
where
    I: IntoIterator<Item = (&'a String, &'a String)>,
{
    let mut merged: HashMap<String, String> = env::vars().collect();
    merged.extend(
        extra
            .into_iter()
            .map(|(key, value)| (key.clone(), value.clone())),
    );
    prepend_build_artifacts_path(&mut merged);
    merged
}

/// Host platform as `(os_name, arch)`.
#[must_use]
pub fn host_platform() -> (&'static str, &'static str) {
    let os_name = if cfg!(target_os = "macos") {
        "darwin"
    } else {
        "linux"
    };
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "amd64"
    };
    (os_name, arch)
}

fn prepend_build_artifacts_path(env: &mut HashMap<String, String>) {
    let Some(repo_root) = env.get("REPO_ROOT") else {
        return;
    };
    if repo_root.is_empty() {
        return;
    }
    let artifacts_dir = primary_kumactl_dir(Path::new(repo_root));
    if !artifacts_dir.is_dir() {
        return;
    }
    let artifacts_str = artifacts_dir.to_string_lossy();
    let current_path = env.get("PATH").cloned().unwrap_or_default();
    env.insert("PATH".into(), format!("{artifacts_str}:{current_path}"));
}

#[cfg(test)]
#[path = "environment/tests.rs"]
mod tests;
