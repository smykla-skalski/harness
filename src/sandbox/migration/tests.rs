use super::*;
use std::fs;
use tempfile::TempDir;

#[test]
fn migrates_when_old_has_data_and_new_empty() {
    let tmp = TempDir::new().unwrap();
    let old = tmp.path().join("old/harness");
    let new = tmp.path().join("new/harness");
    fs::create_dir_all(&old).unwrap();
    fs::write(old.join("session.json"), b"{}").unwrap();
    fs::create_dir_all(new.parent().unwrap()).unwrap();

    let outcome = migrate(&old, &new).unwrap();
    assert!(matches!(outcome, MigrationOutcome::Migrated));
    assert!(new.join("session.json").exists());
    assert!(new.join(".migrated-from").exists());
    assert!(!old.exists() || fs::read_dir(&old).unwrap().next().is_none());
}

#[test]
fn acknowledges_split_when_both_roots_have_content() {
    let tmp = TempDir::new().unwrap();
    let old = tmp.path().join("old/harness");
    let new = tmp.path().join("new/harness");
    fs::create_dir_all(&old).unwrap();
    fs::write(old.join("a.json"), b"{}").unwrap();
    fs::create_dir_all(&new).unwrap();
    fs::write(new.join("b.json"), b"{}").unwrap();

    let first = migrate(&old, &new).unwrap();
    assert_eq!(first, MigrationOutcome::SplitAcknowledged);
    assert!(old.join("a.json").exists());
    assert!(new.join("b.json").exists());
    let split_marker = super::load_split_marker(&new).unwrap().unwrap();
    assert_eq!(split_marker.from_path, old);

    let second = migrate(&old, &new).unwrap();
    assert_eq!(second, MigrationOutcome::SplitAlreadyAcknowledged);
}

#[test]
fn skips_when_old_absent() {
    let tmp = TempDir::new().unwrap();
    let old = tmp.path().join("old/harness");
    let new = tmp.path().join("new/harness");
    fs::create_dir_all(&new).unwrap();

    let outcome = migrate(&old, &new).unwrap();
    assert!(matches!(outcome, MigrationOutcome::SkippedOldAbsent));
}

#[test]
fn returns_already_migrated_when_old_and_new_roots_match() {
    let tmp = TempDir::new().unwrap();
    let root = tmp.path().join("shared/harness");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join("state.json"), b"{}").unwrap();

    let outcome = migrate(&root, &root).unwrap();
    assert!(matches!(outcome, MigrationOutcome::AlreadyMigrated));
    assert!(root.join("state.json").exists());
    assert!(!root.join(".migrated-from").exists());
}

#[test]
fn preserves_symlinks_on_cross_volume_fallback() {
    // Simulate the copy_recursive path directly (cross-volume rename
    // requires distinct mount points which we cannot fabricate here).
    let tmp = TempDir::new().unwrap();
    let src_dir = tmp.path().join("src");
    let dst_dir = tmp.path().join("dst");
    fs::create_dir_all(&src_dir).unwrap();
    std::os::unix::fs::symlink("/nonexistent/target", src_dir.join("link")).unwrap();
    super::copy_recursive(&src_dir, &dst_dir).unwrap();
    let copied = dst_dir.join("link");
    assert!(
        fs::symlink_metadata(&copied)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    assert_eq!(
        fs::read_link(&copied).unwrap(),
        std::path::PathBuf::from("/nonexistent/target")
    );
}

#[test]
fn idempotent_after_marker() {
    let tmp = TempDir::new().unwrap();
    let old = tmp.path().join("old/harness");
    let new = tmp.path().join("new/harness");
    fs::create_dir_all(&old).unwrap();
    fs::write(old.join("x.json"), b"{}").unwrap();

    let first = migrate(&old, &new).unwrap();
    assert!(matches!(first, MigrationOutcome::Migrated));
    let second = migrate(&old, &new).unwrap();
    assert!(matches!(second, MigrationOutcome::AlreadyMigrated));
}

#[test]
fn reacknowledges_split_when_old_root_changes() {
    let tmp = TempDir::new().unwrap();
    let old = tmp.path().join("old/harness");
    let new = tmp.path().join("new/harness");
    fs::create_dir_all(&old).unwrap();
    fs::write(old.join("a.json"), b"{}").unwrap();
    fs::create_dir_all(&new).unwrap();
    fs::write(new.join("b.json"), b"{}").unwrap();

    let first = migrate(&old, &new).unwrap();
    assert_eq!(first, MigrationOutcome::SplitAcknowledged);
    let first_marker = super::load_split_marker(&new).unwrap().unwrap();

    fs::write(old.join("c.json"), b"updated").unwrap();

    let second = migrate(&old, &new).unwrap();
    assert_eq!(second, MigrationOutcome::SplitAcknowledged);
    let second_marker = super::load_split_marker(&new).unwrap().unwrap();
    assert_ne!(first_marker.old_root_digest, second_marker.old_root_digest);

    let third = migrate(&old, &new).unwrap();
    assert_eq!(third, MigrationOutcome::SplitAlreadyAcknowledged);
}

#[test]
fn reacknowledges_when_legacy_root_reappears_after_migration() {
    let tmp = TempDir::new().unwrap();
    let old = tmp.path().join("old/harness");
    let new = tmp.path().join("new/harness");
    fs::create_dir_all(&old).unwrap();
    fs::write(old.join("session.json"), b"{}").unwrap();
    fs::create_dir_all(new.parent().unwrap()).unwrap();

    let first = migrate(&old, &new).unwrap();
    assert_eq!(first, MigrationOutcome::Migrated);
    assert!(new.join(".migrated-from").exists());

    fs::create_dir_all(&old).unwrap();
    fs::write(old.join("legacy.json"), b"{}").unwrap();

    let second = migrate(&old, &new).unwrap();
    assert_eq!(second, MigrationOutcome::SplitAcknowledged);
    assert!(super::load_split_marker(&new).unwrap().is_some());

    let third = migrate(&old, &new).unwrap();
    assert_eq!(third, MigrationOutcome::SplitAlreadyAcknowledged);
}
