use super::*;
use std::path::{Path, PathBuf};

#[test]
fn allowed_path_for_run_metadata() {
    let run_dir = PathBuf::from("/tmp/runs/r1");
    let path = run_dir.join("run-metadata.json");
    assert!(allowed_suite_runner_path(&path, &run_dir));
}

#[test]
fn allowed_path_for_run_dir_subdirectory() {
    let run_dir = PathBuf::from("/tmp/runs/r1");
    let path = run_dir.join("artifacts").join("some-file.txt");
    assert!(allowed_suite_runner_path(&path, &run_dir));
}

#[test]
fn denied_path_outside_run_dir() {
    let run_dir = PathBuf::from("/tmp/runs/r1");
    let path = PathBuf::from("/tmp/other/file.txt");
    assert!(!allowed_suite_runner_path(&path, &run_dir));
}

#[test]
fn file_label_with_filename() {
    assert_eq!(file_label(Path::new("/tmp/foo.txt")), "foo.txt");
}

#[test]
fn file_label_without_filename() {
    assert_eq!(file_label(Path::new("/")), "file");
}
