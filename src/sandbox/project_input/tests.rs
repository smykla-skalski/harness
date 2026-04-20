use super::resolve_project_input;
use tempfile::TempDir;

#[test]
fn returns_canonicalized_path_for_existing_dir() {
    let tmp = TempDir::new().expect("tempdir");
    let input = tmp.path().to_string_lossy().into_owned();
    let scope = resolve_project_input(&input).expect("resolve direct path");
    assert_eq!(
        scope.path(),
        tmp.path().canonicalize().expect("canonicalize")
    );
}

#[test]
fn errors_when_path_does_not_exist() {
    let result = resolve_project_input("/this/path/should/not/exist/anywhere");
    let Err(error) = result else {
        panic!("expected error for missing path");
    };
    assert!(
        error.to_string().contains("could not canonicalize"),
        "expected canonicalization error message, got {error}"
    );
}
