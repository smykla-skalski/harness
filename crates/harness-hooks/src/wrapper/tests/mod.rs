use std::os::unix::fs::PermissionsExt;

use fs_err as fs;

use super::install::{install_wrapper, path_candidates};
use super::*;

mod bootstrap;

#[test]
fn wrapper_content_starts_with_shebang() {
    assert!(WRAPPER.starts_with("#!/bin/sh"));
}

#[test]
fn wrapper_content_references_claude_project_dir() {
    assert!(WRAPPER.contains("CLAUDE_PROJECT_DIR"));
}

#[test]
fn wrapper_content_resolves_repo_binary_directly() {
    assert!(WRAPPER.contains("target/debug/harness"));
    assert!(WRAPPER.contains("command -v harness"));
    assert!(!WRAPPER.contains(".claude/plugins/suite/harness"));
}

#[test]
fn wrapper_content_walks_parent_directories() {
    assert!(WRAPPER.contains("resolve_from_cwd"));
}

#[test]
fn choose_install_dir_prefers_local_bin_on_path() {
    let dir = tempfile::tempdir().unwrap();
    let local_bin = dir.path().join(".local").join("bin");
    fs::create_dir_all(&local_bin).unwrap();

    let path_env = local_bin.to_string_lossy().into_owned();
    let (chosen, on_path) = choose_install_dir_with_home(&path_env, dir.path()).unwrap();
    assert_eq!(
        chosen.canonicalize().unwrap_or(chosen),
        local_bin.canonicalize().unwrap_or(local_bin)
    );
    assert!(on_path);
}

#[test]
fn choose_install_dir_falls_back_to_local_bin_when_local_dir_is_missing() {
    let dir = tempfile::tempdir().unwrap();
    let expected = dir
        .path()
        .canonicalize()
        .unwrap_or_else(|_| dir.path().to_path_buf())
        .join(".local")
        .join("bin");

    let (chosen, on_path) = choose_install_dir_with_home("/usr/bin:/bin", dir.path()).unwrap();

    assert_eq!(chosen, expected);
    assert!(!on_path);
}

#[test]
fn install_wrapper_creates_executable_file() {
    let dir = tempfile::tempdir().unwrap();
    let target_dir = dir.path().join("bin");

    let path = install_wrapper(&target_dir).unwrap();

    assert!(path.exists());
    assert_eq!(fs::read_to_string(&path).unwrap(), WRAPPER);
    let mode = fs::metadata(&path).unwrap().permissions().mode();
    assert_ne!(mode & 0o111, 0, "should be executable");
}

#[test]
fn install_wrapper_is_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let target_dir = dir.path().join("bin");

    let first = install_wrapper(&target_dir).unwrap();
    let second = install_wrapper(&target_dir).unwrap();

    assert_eq!(first, second);
    assert_eq!(fs::read_to_string(&first).unwrap(), WRAPPER);
}

#[test]
fn install_wrapper_preserves_existing_file() {
    let dir = tempfile::tempdir().unwrap();
    let target_dir = dir.path().join("bin");
    fs::create_dir_all(&target_dir).unwrap();
    fs::write(target_dir.join("harness"), "existing content").unwrap();

    let path = install_wrapper(&target_dir).unwrap();
    assert_eq!(fs::read_to_string(path).unwrap(), "existing content");
}

#[test]
fn main_installs_wrapper_without_materializing_suite_plugin() {
    let dir = tempfile::tempdir().unwrap();
    let bin_dir = dir.path().join(".local").join("bin");
    fs::create_dir_all(&bin_dir).unwrap();

    let path_env = bin_dir.to_string_lossy().into_owned();
    let result = main_with_home(dir.path(), &path_env, dir.path());

    assert_eq!(result.unwrap(), 0);
    assert!(bin_dir.join("harness").exists());
    assert!(!dir.path().join(".claude").join("plugins").exists());
}

#[test]
fn path_candidates_deduplicates() {
    let dir = tempfile::tempdir().unwrap();
    let bin = dir.path().join("bin");
    fs::create_dir_all(&bin).unwrap();
    let path_str = format!("{}:{}", bin.display(), bin.display());
    let candidates = path_candidates(&path_str);
    assert_eq!(candidates.len(), 1);
}

#[test]
fn path_candidates_skips_empty_entries() {
    let candidates = path_candidates(":/usr/bin:");
    assert!(!candidates.is_empty());
    assert!(candidates.iter().all(|p| !p.as_os_str().is_empty()));
}
