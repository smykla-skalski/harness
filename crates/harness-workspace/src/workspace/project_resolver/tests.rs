use super::*;
use tempfile::TempDir;

#[test]
fn unique_basenames_use_bare_name() {
    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    let canonical = std::path::PathBuf::from("/Users/b/Projects/kuma");
    let name = resolve_name(&canonical, &sessions).unwrap();
    assert_eq!(name, "kuma");
}

#[test]
fn collision_adds_hash_suffix() {
    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    let first = std::path::PathBuf::from("/Users/b/Projects/kuma");
    let second = std::path::PathBuf::from("/Users/b/Projects-alt/kuma");
    let a = resolve_name(&first, &sessions).unwrap();
    std::fs::create_dir_all(sessions.join(&a)).unwrap();
    write_origin_marker(&sessions.join(&a), &first).unwrap();
    let b = resolve_name(&second, &sessions).unwrap();
    assert_ne!(a, b);
    assert!(b.starts_with("kuma-"));
    assert_eq!(b.len(), "kuma-".len() + 4);
}

#[test]
fn resolves_idempotently() {
    let tmp = TempDir::new().unwrap();
    let sessions = tmp.path().join("sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    let canonical = std::path::PathBuf::from("/Users/b/Projects/kuma");
    let a = resolve_name(&canonical, &sessions).unwrap();
    std::fs::create_dir_all(sessions.join(&a)).unwrap();
    write_origin_marker(&sessions.join(&a), &canonical).unwrap();
    let b = resolve_name(&canonical, &sessions).unwrap();
    assert_eq!(a, b);
}
