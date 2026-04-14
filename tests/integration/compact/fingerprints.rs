use std::fs;
use std::path::{Path, PathBuf};

use harness::workspace::compact::FileFingerprint;

#[test]
fn file_fingerprint_from_existing_file() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("test.txt");
    fs::write(&path, "hello world\n").unwrap();
    let fp = FileFingerprint::from_path("test-label", &path);
    assert!(fp.exists);
    assert_eq!(fp.label, "test-label");
    assert!(fp.size.is_some());
    assert!(fp.sha256.is_some());
}

#[test]
fn file_fingerprint_from_missing_file() {
    let fp = FileFingerprint::from_path("missing", Path::new("/nonexistent/path.txt"));
    assert!(!fp.exists);
    assert!(fp.size.is_none());
    assert!(fp.sha256.is_none());
}

#[test]
fn file_fingerprint_serialization_roundtrip() {
    let fp = FileFingerprint {
        label: "test".into(),
        path: PathBuf::from("/tmp/test.txt"),
        exists: true,
        size: Some(42),
        mtime_ns: Some(1_000_000_000),
        sha256: Some("abc123".into()),
    };
    let json = serde_json::to_string(&fp).unwrap();
    let back: FileFingerprint<'_> = serde_json::from_str(&json).unwrap();
    assert_eq!(fp, back);
}

#[test]
fn file_fingerprint_detects_content_change() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("content.txt");
    fs::write(&path, "version 1\n").unwrap();
    let fp1 = FileFingerprint::from_path("test", &path);
    fs::write(&path, "version 2\n").unwrap();
    let fp2 = FileFingerprint::from_path("test", &path);
    assert_ne!(fp1.sha256, fp2.sha256);
}
