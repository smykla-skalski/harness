use std::fs;
use std::path::{Path, PathBuf};

use super::*;

#[test]
fn state_path_includes_state_dir() {
    let path = state_path(Path::new("/runs/r1"));
    assert_eq!(
        path,
        PathBuf::from("/runs/r1/state/ephemeral-metallb-templates.json")
    );
}

#[test]
fn template_path_formats_cluster_name() {
    let path = template_path(Path::new("/repo"), "kuma-1").unwrap();
    assert_eq!(path, PathBuf::from("/repo/mk/metallb-k3d-kuma-1.yaml"));
}

#[test]
fn template_path_rejects_traversal() {
    let err = template_path(Path::new("/repo"), "../evil").unwrap_err();
    assert_eq!(err.code(), "KSRCLI059");
}

#[test]
fn template_path_rejects_slash() {
    let err = template_path(Path::new("/repo"), "a/b").unwrap_err();
    assert_eq!(err.code(), "KSRCLI059");
}

#[test]
fn ensure_templates_creates_copies() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mk = root.join("mk");
    fs::create_dir_all(&mk).unwrap();
    fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "template content").unwrap();

    let run_dir = dir.path().join("run");
    fs::create_dir_all(&run_dir).unwrap();

    let created = ensure_templates(root, &["c1", "c2"], Some(&run_dir)).unwrap();

    assert_eq!(created.len(), 2);
    for path in &created {
        assert!(path.exists());
        assert_eq!(fs::read_to_string(path).unwrap(), "template content");
    }
}

#[test]
fn ensure_templates_skips_existing() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mk = root.join("mk");
    fs::create_dir_all(&mk).unwrap();
    fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "base").unwrap();
    fs::write(mk.join("metallb-k3d-existing.yaml"), "already here").unwrap();

    let created = ensure_templates(root, &["existing"], None).unwrap();
    assert!(created.is_empty());
}

#[test]
fn ensure_templates_records_state() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mk = root.join("mk");
    fs::create_dir_all(&mk).unwrap();
    fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "base").unwrap();

    let run_dir = dir.path().join("run");
    fs::create_dir_all(&run_dir).unwrap();

    ensure_templates(root, &["c1"], Some(&run_dir)).unwrap();
    assert!(state_path(&run_dir).exists());
}

#[test]
fn cleanup_templates_removes_created_files() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mk = root.join("mk");
    fs::create_dir_all(&mk).unwrap();
    fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "base").unwrap();

    let run_dir = dir.path().join("run");
    fs::create_dir_all(&run_dir).unwrap();

    let created = ensure_templates(root, &["local"], Some(&run_dir)).unwrap();
    assert_eq!(created.len(), 1);
    assert!(created[0].exists());

    let removed = cleanup_templates(&run_dir).unwrap();
    assert_eq!(removed.len(), 1);
    assert!(!created[0].exists());
}

#[test]
fn cleanup_templates_returns_empty_when_no_state() {
    let dir = tempfile::tempdir().unwrap();
    let removed = cleanup_templates(dir.path()).unwrap();
    assert!(removed.is_empty());
}

#[test]
fn restore_templates_recreates_from_source() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mk = root.join("mk");
    fs::create_dir_all(&mk).unwrap();
    fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "base").unwrap();

    let run_dir = dir.path().join("run");
    fs::create_dir_all(&run_dir).unwrap();

    let created = ensure_templates(root, &["restore-test"], Some(&run_dir)).unwrap();
    assert_eq!(created.len(), 1);

    fs::remove_file(&created[0]).unwrap();
    assert!(!created[0].exists());

    let restored = restore_templates(&run_dir).unwrap();
    assert_eq!(restored.len(), 1);
    assert!(created[0].exists());
}

#[test]
fn restore_templates_skips_already_existing() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mk = root.join("mk");
    fs::create_dir_all(&mk).unwrap();
    fs::write(mk.join(DEFAULT_TEMPLATE_BASENAME), "base").unwrap();

    let run_dir = dir.path().join("run");
    fs::create_dir_all(&run_dir).unwrap();

    ensure_templates(root, &["skip-test"], Some(&run_dir)).unwrap();

    let restored = restore_templates(&run_dir).unwrap();
    assert!(restored.is_empty());
}

#[test]
fn load_entries_propagates_corrupt_state() {
    let dir = tempfile::tempdir().unwrap();
    let run_dir = dir.path().join("run");
    let state_dir = run_dir.join("state");
    fs::create_dir_all(&state_dir).unwrap();
    fs::write(state_dir.join(STATE_FILE), "not json {").unwrap();
    let err = load_entries(Some(&run_dir)).unwrap_err();
    assert_eq!(err.code(), "KSRCLI019");
}

#[test]
fn ensure_templates_fails_when_no_source() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let err = ensure_templates(root, &["c1"], None).unwrap_err();
    assert_eq!(err.code(), "KSRCLI014");
}

#[test]
fn default_source_template_finds_fallback() {
    let dir = tempfile::tempdir().unwrap();
    let mk = dir.path().join("mk");
    fs::create_dir_all(&mk).unwrap();
    fs::write(mk.join("metallb-k3d-custom.yaml"), "custom").unwrap();

    let source = default_source_template(dir.path()).unwrap();
    assert!(source.to_string_lossy().contains("metallb-k3d-custom.yaml"));
}
