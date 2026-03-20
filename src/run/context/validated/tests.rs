use super::{RunLayout, ValidatedRunLayout};

#[test]
fn validated_layout_succeeds_for_existing_dir() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = RunLayout::new(tmp.path().to_string_lossy().into_owned(), "test-run");
    layout.ensure_dirs().unwrap();

    let validated = ValidatedRunLayout::new(layout).expect("should succeed for existing dir");
    assert!(validated.run_dir().is_dir());
    assert_eq!(validated.inner().run_id, "test-run");
}

#[test]
fn validated_layout_fails_for_missing_dir() {
    let layout = RunLayout::new("/nonexistent/path", "vanished");
    let result = ValidatedRunLayout::new(layout);
    assert!(result.is_err());
    let error = result.unwrap_err();
    assert_eq!(error.code(), "KSRCLI014");
    assert!(error.message().contains("vanished"));
}

fn make_validated() -> (ValidatedRunLayout, RunLayout, tempfile::TempDir) {
    let tmp = tempfile::tempdir().unwrap();
    let layout = RunLayout::new(tmp.path().to_string_lossy().into_owned(), "run-x");
    layout.ensure_dirs().unwrap();
    let validated = ValidatedRunLayout::new(layout.clone()).unwrap();
    (validated, layout, tmp)
}

#[test]
fn validated_layout_delegates_directory_paths() {
    let (validated, layout, _tmp) = make_validated();
    assert_eq!(validated.run_dir(), layout.run_dir());
    assert_eq!(validated.artifacts_dir(), layout.artifacts_dir());
    assert_eq!(validated.commands_dir(), layout.commands_dir());
    assert_eq!(validated.state_dir(), layout.state_dir());
}

#[test]
fn validated_layout_delegates_file_paths() {
    let (validated, layout, _tmp) = make_validated();
    assert_eq!(validated.manifests_dir(), layout.manifests_dir());
    assert_eq!(validated.metadata_path(), layout.metadata_path());
    assert_eq!(validated.status_path(), layout.status_path());
    assert_eq!(validated.report_path(), layout.report_path());
}

#[test]
fn validated_layout_into_inner_returns_original() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = RunLayout::new(tmp.path().to_string_lossy().into_owned(), "run-y");
    layout.ensure_dirs().unwrap();
    let validated = ValidatedRunLayout::new(layout.clone()).unwrap();
    let recovered = validated.into_inner();
    assert_eq!(recovered, layout);
}
