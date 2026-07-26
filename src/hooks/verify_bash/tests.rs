use super::*;
use std::fs;

#[test]
fn subcommand_artifacts_apply() {
    let arts = subcommand_artifacts("apply").unwrap();
    assert!(arts.contains(&"manifests"));
}

#[test]
fn subcommand_artifacts_capture() {
    let arts = subcommand_artifacts("capture").unwrap();
    assert!(arts.contains(&"state"));
}

#[test]
fn subcommand_artifacts_record() {
    let arts = subcommand_artifacts("record").unwrap();
    assert!(arts.contains(&"commands"));
}

#[test]
fn subcommand_artifacts_unknown() {
    assert!(subcommand_artifacts("unknown").is_none());
}

// -- has_table_rows --

#[test]
fn has_table_rows_with_enough_rows() {
    let tmp = tempfile::NamedTempFile::new().unwrap();
    fs::write(tmp.path(), "| h1 | h2 |\n|---|---|\n| a | b |\n| c | d |\n").unwrap();
    assert!(has_table_rows(tmp.path()));
}

#[test]
fn has_table_rows_with_too_few() {
    let tmp = tempfile::NamedTempFile::new().unwrap();
    fs::write(tmp.path(), "| h1 | h2 |\n|---|---|\n").unwrap();
    assert!(!has_table_rows(tmp.path()));
}

#[test]
fn has_table_rows_missing_file() {
    assert!(!has_table_rows(Path::new(
        "/418cf829-6691-5fc0-92b1-8e5013efa2cb/path/file.md"
    )));
}
