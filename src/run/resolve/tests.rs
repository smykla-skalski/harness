use std::fs;
use std::path::PathBuf;

use super::*;

#[test]
fn resolve_run_directory_with_existing_dir() {
    let dir = tempfile::tempdir().unwrap();
    let resolved = resolve_run_directory(Some(dir.path()), None, None).unwrap();
    assert_eq!(resolved.run_dir, dir.path());
}

#[test]
fn resolve_run_directory_with_root_and_id() {
    let dir = tempfile::tempdir().unwrap();
    let run_dir = dir.path().join("my-run");
    fs::create_dir(&run_dir).unwrap();
    let resolved = resolve_run_directory(None, Some("my-run"), Some(dir.path())).unwrap();
    assert_eq!(resolved.run_dir, run_dir);
}

#[test]
fn resolve_run_directory_missing_returns_error() {
    let tmp = tempfile::tempdir().unwrap();
    let missing_root = tmp.path().join("nonexistent");
    let err = resolve_run_directory(None, Some("ghost"), Some(missing_root.as_path())).unwrap_err();
    assert_eq!(err.code(), "KSRCLI018");
}

#[test]
fn resolve_run_directory_no_fields_returns_pointer_error() {
    let tmp = tempfile::tempdir().unwrap();
    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(tmp.path().to_str().unwrap())),
            ("CLAUDE_SESSION_ID", Some("resolve-no-pointer-test")),
        ],
        || {
            let err = resolve_run_directory(None, None, None).unwrap_err();
            assert_eq!(err.code(), "KSRCLI005");
        },
    );
}

#[test]
fn resolve_run_directory_falls_back_to_current_run_pointer() {
    use crate::run::context::{CurrentRunRecord, RunLayout};

    let tmp = tempfile::tempdir().unwrap();

    let run_dir = tmp.path().join("runs").join("fallback-run");
    fs::create_dir_all(&run_dir).unwrap();

    let record = CurrentRunRecord {
        layout: RunLayout::new(
            tmp.path().join("runs").to_string_lossy().into_owned(),
            "fallback-run",
        ),
        profile: None,
        repo_root: None,
        suite_dir: None,
        suite_id: None,
        suite_path: None,
        cluster: None,
        keep_clusters: false,
        user_stories: vec![],
        requires: vec![],
    };

    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().join("xdg").to_str().unwrap()),
            ),
            ("CLAUDE_SESSION_ID", Some("resolve-fallback-test")),
        ],
        || {
            let ctx_path = workspace::current_run_context_path().unwrap();
            fs::create_dir_all(ctx_path.parent().unwrap()).unwrap();
            fs::write(&ctx_path, serde_json::to_string_pretty(&record).unwrap()).unwrap();

            let resolved = resolve_run_directory(None, None, None).unwrap();
            assert_eq!(resolved.run_dir, run_dir);
        },
    );
}

#[test]
fn resolve_run_directory_only_run_id_returns_location_error() {
    let err = resolve_run_directory(None, Some("orphan"), None).unwrap_err();
    assert_eq!(err.code(), "KSRCLI018");
}

#[test]
fn resolve_manifest_path_absolute_existing() {
    let dir = tempfile::tempdir().unwrap();
    let manifest = dir.path().join("test.yaml");
    fs::write(&manifest, "content").unwrap();
    let result = resolve_manifest_path(&manifest.to_string_lossy(), None).unwrap();
    assert_eq!(result, manifest);
}

#[test]
fn resolve_manifest_path_in_run_dir() {
    let dir = tempfile::tempdir().unwrap();
    let groups_dir = dir.path().join("manifests").join("prepared").join("groups");
    fs::create_dir_all(&groups_dir).unwrap();
    let manifest = groups_dir.join("g01.yaml");
    fs::write(&manifest, "content").unwrap();

    let result = resolve_manifest_path("g01.yaml", Some(dir.path())).unwrap();
    assert_eq!(result, manifest);
}

#[test]
fn resolve_manifest_path_not_found_returns_error() {
    let err = resolve_manifest_path("ghost.yaml", None).unwrap_err();
    assert_eq!(err.code(), "KSRCLI014");
}

#[test]
fn resolve_manifest_path_leading_slash_treated_as_relative() {
    let dir = tempfile::tempdir().unwrap();
    let groups_dir = dir.path().join("manifests").join("prepared").join("groups");
    let nested = groups_dir.join("g09");
    fs::create_dir_all(&nested).unwrap();
    let manifest = nested.join("01.yaml");
    fs::write(&manifest, "content").unwrap();

    let result = resolve_manifest_path("/g09/01.yaml", Some(dir.path())).unwrap();
    assert_eq!(result, manifest);
}

#[test]
fn suite_path_candidates_bare_name_includes_suite_root() {
    let suite_root = PathBuf::from("/suites");
    let candidates = suite_path_candidates("my-suite", &suite_root).unwrap();
    assert!(candidates.len() >= 2);
    assert_eq!(candidates[1], PathBuf::from("/suites/my-suite/suite.md"));
}

#[test]
fn suite_path_candidates_with_slash_skips_suite_root() {
    let suite_root = PathBuf::from("/suites");
    let candidates = suite_path_candidates("path/to/suite.md", &suite_root).unwrap();
    assert_eq!(candidates.len(), 1);
}

#[test]
fn normalize_suite_candidate_appends_suite_md_for_dirs() {
    let dir = tempfile::tempdir().unwrap();
    let result = normalize_suite_candidate(dir.path());
    assert_eq!(result, dir.path().join("suite.md"));
}

#[test]
fn normalize_suite_candidate_preserves_file_path() {
    let path = PathBuf::from("/some/suite.md");
    let result = normalize_suite_candidate(&path);
    assert_eq!(result, path);
}
