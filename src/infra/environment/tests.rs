use super::*;
use std::env;
use std::fs;
use std::iter;

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
    fs::create_dir_all(&artifacts_dir).unwrap();

    let mut extra = HashMap::new();
    extra.insert(
        "REPO_ROOT".into(),
        tmp.path().to_string_lossy().into_owned(),
    );
    let merged = merge_env(extra.iter());
    let path_val = merged.get("PATH").unwrap();
    let expected_prefix = artifacts_dir.to_string_lossy();
    assert!(path_val.starts_with(expected_prefix.as_ref()));
}

#[test]
fn merge_env_skips_artifacts_when_dir_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let mut extra = HashMap::new();
    extra.insert(
        "REPO_ROOT".into(),
        tmp.path().to_string_lossy().into_owned(),
    );
    let original_path = env::var("PATH").unwrap_or_default();
    let merged = merge_env(extra.iter());
    assert_eq!(merged.get("PATH").unwrap(), &original_path);
}

#[test]
fn merge_env_no_repo_root_leaves_path_unchanged() {
    let original_path = env::var("PATH").unwrap_or_default();
    let merged = merge_env(iter::empty());
    assert_eq!(merged.get("PATH").unwrap(), &original_path);
}
