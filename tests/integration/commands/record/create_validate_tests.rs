use std::fs;

use harness::create::CreateValidateArgs;

use super::super::super::helpers::*;

#[test]
fn create_validate_accepts_valid_meshmetric_group() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();

    let yaml = tmp.path().join("valid.yaml");
    fs::write(
        &yaml,
        "apiVersion: kuma.io/v1alpha1\nkind: MeshMetric\nmetadata:\n  name: test\n",
    )
    .unwrap();

    let paths = vec![yaml.to_string_lossy().to_string()];
    let result = create_validate_cmd(CreateValidateArgs {
        path: paths,
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok(), "valid yaml should pass: {result:?}");
}

#[test]
fn create_validate_rejects_invalid_meshmetric_group() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();

    let md = tmp.path().join("bad.md");
    fs::write(&md, "# Not yaml").unwrap();

    let paths = vec![md.to_string_lossy().to_string()];
    let result = create_validate_cmd(CreateValidateArgs {
        path: paths,
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());
}

#[test]
fn create_validate_ignores_universal_format() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();

    let txt = tmp.path().join("universal.txt");
    fs::write(&txt, "universal format block").unwrap();

    let paths = vec![txt.to_string_lossy().to_string()];
    let result = create_validate_cmd(CreateValidateArgs {
        path: paths,
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok(), "universal format should be skipped");
}

#[test]
fn create_validate_skips_expected_rejection_manifests() {
    let tmp = tempfile::tempdir().unwrap();
    let repo_root = tmp.path().join("repo");
    fs::create_dir_all(&repo_root).unwrap();

    let yaml = tmp.path().join("reject.yaml");
    fs::write(
        &yaml,
        "apiVersion: kuma.io/v1alpha1\nkind: MeshTimeout\nmetadata:\n  name: bad-policy\n",
    )
    .unwrap();

    let paths = vec![yaml.to_string_lossy().to_string()];
    let result = create_validate_cmd(CreateValidateArgs {
        path: paths,
        repo_root: Some(repo_root.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());
}
