use std::env;
use std::fs;
use std::path::{Path, PathBuf};

use super::*;

#[test]
fn suite_defaults_path_joins_correctly() {
    let path = suite_defaults_path(Path::new("/suites/my-suite"));
    assert_eq!(path, PathBuf::from("/suites/my-suite/.harness.json"));
}

#[test]
fn defaults_file_constant() {
    assert_eq!(DEFAULTS_FILE, ".harness.json");
}

#[test]
fn write_and_load_suite_defaults_no_repo_root() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(&suite_dir).unwrap();

    let path = write_suite_defaults(&suite_dir, None).unwrap();
    assert!(path.exists());
    assert_eq!(path.file_name().unwrap(), ".harness.json");

    let loaded = load_suite_defaults(&suite_dir).unwrap();
    assert!(loaded.is_some());
    let val = loaded.unwrap();
    assert!(val.repo_root.is_none());
}

#[test]
fn write_and_load_suite_defaults_with_repo_root() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&suite_dir).unwrap();
    fs::create_dir_all(&repo_root).unwrap();

    write_suite_defaults(&suite_dir, Some(&repo_root)).unwrap();

    let loaded = load_suite_defaults(&suite_dir).unwrap().unwrap();
    let stored_root = loaded.repo_root.unwrap();
    assert!(stored_root.contains("repo"));
}

#[test]
fn load_suite_defaults_missing_file_returns_none() {
    let tmp = tempfile::tempdir().unwrap();
    let result = load_suite_defaults(tmp.path()).unwrap();
    assert!(result.is_none());
}

#[test]
fn default_repo_root_for_suite_returns_path() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&suite_dir).unwrap();
    fs::create_dir_all(&repo_root).unwrap();

    write_suite_defaults(&suite_dir, Some(&repo_root)).unwrap();

    let result = default_repo_root_for_suite(&suite_dir);
    assert!(result.is_some());
    let root = result.unwrap();
    assert!(root.display().to_string().contains("repo"));
}

#[test]
fn default_repo_root_for_suite_returns_none_when_missing() {
    let tmp = tempfile::tempdir().unwrap();
    let result = default_repo_root_for_suite(tmp.path());
    assert!(result.is_none());
}

#[test]
fn default_repo_root_for_suite_returns_none_when_no_key() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(&suite_dir).unwrap();

    write_suite_defaults(&suite_dir, None).unwrap();

    let result = default_repo_root_for_suite(&suite_dir);
    assert!(result.is_none());
}

#[test]
fn find_suite_dir_by_suite_md() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("my-suite");
    fs::create_dir_all(&suite_dir).unwrap();
    fs::write(suite_dir.join("suite.md"), "# Suite").unwrap();

    let result = find_suite_dir(&suite_dir);
    assert_eq!(result, Some(suite_dir));
}

#[test]
fn find_suite_dir_from_suite_md_file_path() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("my-suite");
    fs::create_dir_all(&suite_dir).unwrap();
    let suite_md = suite_dir.join("suite.md");
    fs::write(&suite_md, "# Suite").unwrap();

    let result = find_suite_dir(&suite_md);
    assert_eq!(result, Some(suite_dir));
}

#[test]
fn find_suite_dir_from_child_directory() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("my-suite");
    let child = suite_dir.join("groups").join("g01");
    fs::create_dir_all(&child).unwrap();
    fs::write(suite_dir.join("suite.md"), "# Suite").unwrap();

    let result = find_suite_dir(&child);
    assert_eq!(result, Some(suite_dir));
}

#[test]
fn find_suite_dir_by_defaults_file() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("my-suite");
    fs::create_dir_all(&suite_dir).unwrap();

    write_suite_defaults(&suite_dir, None).unwrap();

    let result = find_suite_dir(&suite_dir);
    assert_eq!(result, Some(suite_dir));
}

#[test]
fn find_suite_dir_returns_none_for_empty_tree() {
    let tmp = tempfile::tempdir().unwrap();
    let result = find_suite_dir(tmp.path());
    assert!(result.is_none());
}

#[test]
fn write_suite_defaults_creates_directory() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("new-suite");
    assert!(!suite_dir.exists());

    let path = write_suite_defaults(&suite_dir, None).unwrap();
    assert!(path.exists());
    assert!(suite_dir.exists());
}

#[test]
fn find_suite_dir_accepts_relative_paths() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_dir = tmp.path().join("suite");
    fs::create_dir_all(&suite_dir).unwrap();
    fs::write(suite_dir.join("suite.md"), "# Suite").unwrap();

    let old_dir = env::current_dir().unwrap();
    env::set_current_dir(tmp.path()).unwrap();
    let result = find_suite_dir(Path::new("suite"));
    env::set_current_dir(old_dir).unwrap();

    assert_eq!(
        result.unwrap().canonicalize().unwrap(),
        suite_dir.canonicalize().unwrap()
    );
}

fn find_suite_dir(path: &Path) -> Option<PathBuf> {
    let resolved = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir().ok()?.join(path)
    };

    if resolved.file_name().is_some_and(|n| n == "suite.md") && resolved.is_file() {
        return resolved.parent().map(Path::to_path_buf);
    }

    let start = if resolved.is_dir() {
        resolved
    } else {
        resolved.parent()?.to_path_buf()
    };

    let mut current = Some(start.as_path());
    while let Some(dir) = current {
        if dir.join("suite.md").is_file() {
            return Some(dir.to_path_buf());
        }
        if suite_defaults_path(dir).is_file() {
            return Some(dir.to_path_buf());
        }
        current = dir.parent();
    }
    None
}
