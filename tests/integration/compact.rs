// Compact/fingerprint integration tests.
// Tests FileFingerprint creation, serialization, content change detection,
// and compact handoff commands (ignored - requires CLI binary).

use std::fs;
use std::path::Path;

use harness::compact::FileFingerprint;

// ============================================================================
// FileFingerprint tests (pure unit, no external deps)
// ============================================================================

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
        label: "test".to_string(),
        path: "/tmp/test.txt".to_string(),
        exists: true,
        size: Some(42),
        mtime_ns: Some(1_000_000_000),
        sha256: Some("abc123".to_string()),
    };
    let json = serde_json::to_string(&fp).unwrap();
    let back: FileFingerprint = serde_json::from_str(&json).unwrap();
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

// ============================================================================
// Compact handoff tests (require CLI binary and project/session state)
// ============================================================================

#[test]
#[ignore = "Requires CLI binary with pre-compact command"]
fn build_compact_includes_runner() {
    // build_compact_handoff should include suite_runner state
}

#[test]
#[ignore = "Requires CLI binary and worktree project"]
fn build_compact_worktree_project() {
    // build_compact_handoff should find runner from worktree project state
}

#[test]
#[ignore = "Requires CLI binary and authoring session"]
fn build_compact_includes_author() {
    // build_compact_handoff should include suite_author saved payloads
}

#[test]
#[ignore = "Requires CLI binary and CWD-scoped authoring"]
fn build_compact_author_fallback() {
    // build_compact_handoff reads author payloads from fallback scope
}

#[test]
#[ignore = "Requires CLI binary"]
fn save_consume_compact_handoff() {
    // save_compact_handoff writes latest, history, and session copy.
    // consume_compact_handoff marks consumed.
}

#[test]
#[ignore = "Requires CLI binary"]
fn pre_compact_persists() {
    // harness pre-compact should persist pending handoff
}

#[test]
#[ignore = "Requires CLI binary"]
fn session_start_compact_hydrates() {
    // harness session-start --source compact should emit hydration context
}

#[test]
#[ignore = "Requires CLI binary and worktree"]
fn session_start_compact_worktree() {
    // session-start compact restores runner from worktree project state
}

#[test]
#[ignore = "Requires CLI binary"]
fn session_start_compact_aborted_resume() {
    // session-start compact guides aborted run resume without manual edits
}

#[test]
#[ignore = "Requires CLI binary"]
fn session_start_compact_restores_author() {
    // session-start compact restores suite author state for new session
}

#[test]
#[ignore = "Requires CLI binary"]
fn session_start_compact_divergence_warning() {
    // session-start compact warns when saved files diverge from live state
}

#[test]
#[ignore = "Requires CLI binary"]
fn session_start_restores_project() {
    // session-start restores active run from project state
}

#[test]
#[ignore = "Requires CLI binary and worktree"]
fn session_start_restores_worktree() {
    // session-start restores active run from related worktree project state
}

#[test]
#[ignore = "Requires CLI binary and multi-project setup"]
fn session_start_cross_project() {
    // session-start restores project run when current session points elsewhere
}

#[test]
#[ignore = "Requires CLI binary and metallb templates"]
fn session_start_metallb_templates() {
    // session-start restores temporary metallb templates for pending run
}

#[test]
#[ignore = "Requires CLI binary and metallb templates"]
fn session_stop_metallb_cleanup() {
    // session-stop cleans temporary metallb templates for pending run
}

#[test]
#[ignore = "Requires CLI binary"]
fn session_start_no_replay() {
    // session-start compact does not replay consumed handoff
}
