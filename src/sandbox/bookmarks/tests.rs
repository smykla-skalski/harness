use super::*;
use std::io::Write;
use tempfile::TempDir;

#[test]
fn round_trip_save_load() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("bookmarks.json");

    let store = PersistedStore {
        schema_version: PersistedStore::CURRENT_SCHEMA_VERSION,
        bookmarks: vec![Record {
            id: "B-test".into(),
            kind: Kind::ProjectRoot,
            display_name: "kuma".into(),
            last_resolved_path: "/tmp/kuma".into(),
            bookmark_data: vec![1, 2, 3],
            handoff_bookmark_data: Some(vec![4, 5, 6]),
            created_at: chrono::Utc::now(),
            last_accessed_at: chrono::Utc::now(),
            stale_count: 0,
        }],
    };
    save(&path, &store).unwrap();

    let loaded = load(&path).unwrap();
    assert_eq!(loaded.bookmarks.len(), 1);
    assert_eq!(loaded.bookmarks[0].id, "B-test");
    assert_eq!(
        loaded.bookmarks[0].handoff_bookmark_data,
        Some(vec![4, 5, 6])
    );
}

#[test]
fn load_unsupported_schema_version_errors() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("bookmarks.json");
    let mut f = std::fs::File::create(&path).unwrap();
    f.write_all(br#"{"schemaVersion": 99, "bookmarks": []}"#)
        .unwrap();

    let err = load(&path).unwrap_err();
    match err {
        BookmarkError::UnsupportedSchemaVersion { found, expected } => {
            assert_eq!(found, 99);
            assert_eq!(expected, PersistedStore::CURRENT_SCHEMA_VERSION);
        }
        _ => panic!("unexpected error: {err:?}"),
    }
}

#[test]
fn load_missing_file_returns_empty() {
    let dir = TempDir::new().unwrap();
    let loaded = load(&dir.path().join("absent.json")).unwrap();
    assert!(loaded.bookmarks.is_empty());
    assert_eq!(
        loaded.schema_version,
        PersistedStore::CURRENT_SCHEMA_VERSION
    );
}
