use std::collections::HashMap;
use std::env;
use std::path::Path;

/// Merge current env with extra key-value pairs.
///
/// When the merged env contains `REPO_ROOT`, the build artifacts directory
/// for the host platform is prepended to `PATH` so that locally-built
/// binaries (like `kumactl`) are found before system-installed ones.
#[must_use]
pub fn merge_env(extra: Option<&HashMap<String, String>>) -> HashMap<String, String> {
    let mut env: HashMap<String, String> = env::vars().collect();
    if let Some(extra) = extra {
        env.extend(extra.iter().map(|(k, v)| (k.clone(), v.clone())));
    }
    prepend_build_artifacts_path(&mut env);
    env
}

/// Host platform as `(os_name, arch)` - e.g. `("darwin", "arm64")`.
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

/// If `REPO_ROOT` is set, prepend `{repo_root}/build/artifacts-{os}-{arch}/kumactl`
/// to `PATH` so locally-built binaries are preferred over system ones.
fn prepend_build_artifacts_path(env: &mut HashMap<String, String>) {
    let Some(repo_root) = env.get("REPO_ROOT") else {
        return;
    };
    if repo_root.is_empty() {
        return;
    }
    let (os_name, arch) = host_platform();
    let artifacts_dir = Path::new(repo_root)
        .join("build")
        .join(format!("artifacts-{os_name}-{arch}"))
        .join("kumactl");
    if !artifacts_dir.is_dir() {
        return;
    }
    let artifacts_str = artifacts_dir.to_string_lossy();
    let current_path = env.get("PATH").cloned().unwrap_or_default();
    env.insert("PATH".into(), format!("{artifacts_str}:{current_path}"));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_env_prepends_build_artifacts_to_path() {
        let tmp = tempfile::tempdir().unwrap();
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
        let artifacts_dir = tmp
            .path()
            .join("build")
            .join(format!("artifacts-{os_name}-{arch}"))
            .join("kumactl");
        std::fs::create_dir_all(&artifacts_dir).unwrap();

        let mut extra = HashMap::new();
        extra.insert(
            "REPO_ROOT".into(),
            tmp.path().to_string_lossy().into_owned(),
        );
        let merged = merge_env(Some(&extra));
        let path_val = merged.get("PATH").unwrap();
        let expected_prefix = artifacts_dir.to_string_lossy();
        assert!(
            path_val.starts_with(expected_prefix.as_ref()),
            "PATH should start with artifacts dir, got: {path_val}"
        );
    }

    #[test]
    fn merge_env_skips_artifacts_when_dir_missing() {
        let tmp = tempfile::tempdir().unwrap();
        // No build directory created - artifacts dir does not exist
        let mut extra = HashMap::new();
        extra.insert(
            "REPO_ROOT".into(),
            tmp.path().to_string_lossy().into_owned(),
        );
        let original_path = env::var("PATH").unwrap_or_default();
        let merged = merge_env(Some(&extra));
        let path_val = merged.get("PATH").unwrap();
        assert_eq!(
            path_val, &original_path,
            "PATH should be unchanged when artifacts dir does not exist"
        );
    }

    #[test]
    fn merge_env_no_repo_root_leaves_path_unchanged() {
        let original_path = env::var("PATH").unwrap_or_default();
        let merged = merge_env(None);
        let path_val = merged.get("PATH").unwrap();
        assert_eq!(path_val, &original_path);
    }

    #[test]
    fn prepend_build_artifacts_path_ignores_empty_repo_root() {
        let mut env_map = HashMap::new();
        env_map.insert("REPO_ROOT".into(), String::new());
        env_map.insert("PATH".into(), "/usr/bin".into());
        prepend_build_artifacts_path(&mut env_map);
        assert_eq!(env_map.get("PATH").unwrap(), "/usr/bin");
    }
}
