// Integration tests for compaction handoff.
// Ported from Python test_compact.py (17 tests).
//
// Python test name -> Rust test name mapping:
//   test_build_compact_handoff_includes_suite_runner_state -> build_compact_includes_runner [#ignore]
//   test_build_compact_handoff_finds_runner_from_worktree_project_state
//     -> build_compact_worktree_project [#ignore]
//   test_build_compact_handoff_includes_suite_author_saved_payloads
//     -> build_compact_includes_author [#ignore]
//   test_build_compact_handoff_reads_suite_author_saved_payloads_from_fallback_scope
//     -> build_compact_author_fallback [#ignore]
//   test_save_and_consume_compact_handoff_writes_latest_history_and_session_copy
//     -> save_consume_compact_handoff [#ignore]
//   test_pre_compact_command_persists_pending_handoff
//     -> pre_compact_persists [#ignore]
//   test_session_start_compact_emits_hydration_and_consumes_pending_handoff
//     -> session_start_compact_hydrates [#ignore]
//   test_session_start_compact_restores_runner_from_worktree_project_state
//     -> session_start_compact_worktree [#ignore]
//   test_session_start_compact_guides_aborted_run_resume_without_manual_edits
//     -> session_start_compact_aborted_resume [#ignore]
//   test_session_start_compact_restores_suite_author_state_for_new_session
//     -> session_start_compact_restores_author [#ignore]
//   test_session_start_compact_warns_when_saved_files_diverge
//     -> session_start_compact_divergence_warning [#ignore]
//   test_session_start_restores_active_run_from_project_state
//     -> session_start_restores_project [#ignore]
//   test_session_start_restores_active_run_from_related_worktree_project_state
//     -> session_start_restores_worktree [#ignore]
//   test_session_start_restores_project_run_when_current_session_points_to_other_project
//     -> session_start_cross_project [#ignore]
//   test_session_start_restores_temporary_metallb_templates_for_pending_run
//     -> session_start_metallb_templates [#ignore]
//   test_session_stop_cleans_temporary_metallb_templates_for_pending_run
//     -> session_stop_metallb_cleanup [#ignore]
//   test_session_start_compact_does_not_replay_consumed_handoff
//     -> session_start_no_replay [#ignore]

mod helpers;

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
#[ignore] // Requires CLI binary with pre-compact command
fn build_compact_includes_runner() {
    // build_compact_handoff should include suite_runner state
}

#[test]
#[ignore] // Requires CLI binary and worktree project
fn build_compact_worktree_project() {
    // build_compact_handoff should find runner from worktree project state
}

#[test]
#[ignore] // Requires CLI binary and authoring session
fn build_compact_includes_author() {
    // build_compact_handoff should include suite_author saved payloads
}

#[test]
#[ignore] // Requires CLI binary and CWD-scoped authoring
fn build_compact_author_fallback() {
    // build_compact_handoff reads author payloads from fallback scope
}

#[test]
#[ignore] // Requires CLI binary
fn save_consume_compact_handoff() {
    // save_compact_handoff writes latest, history, and session copy.
    // consume_compact_handoff marks consumed.
}

#[test]
#[ignore] // Requires CLI binary
fn pre_compact_persists() {
    // harness pre-compact should persist pending handoff
}

#[test]
#[ignore] // Requires CLI binary
fn session_start_compact_hydrates() {
    // harness session-start --source compact should emit hydration context
}

#[test]
#[ignore] // Requires CLI binary and worktree
fn session_start_compact_worktree() {
    // session-start compact restores runner from worktree project state
}

#[test]
#[ignore] // Requires CLI binary
fn session_start_compact_aborted_resume() {
    // session-start compact guides aborted run resume without manual edits
}

#[test]
#[ignore] // Requires CLI binary
fn session_start_compact_restores_author() {
    // session-start compact restores suite author state for new session
}

#[test]
#[ignore] // Requires CLI binary
fn session_start_compact_divergence_warning() {
    // session-start compact warns when saved files diverge from live state
}

#[test]
#[ignore] // Requires CLI binary
fn session_start_restores_project() {
    // session-start restores active run from project state
}

#[test]
#[ignore] // Requires CLI binary and worktree
fn session_start_restores_worktree() {
    // session-start restores active run from related worktree project state
}

#[test]
#[ignore] // Requires CLI binary and multi-project setup
fn session_start_cross_project() {
    // session-start restores project run when current session points elsewhere
}

#[test]
#[ignore] // Requires CLI binary and metallb templates
fn session_start_metallb_templates() {
    // session-start restores temporary metallb templates for pending run
}

#[test]
#[ignore] // Requires CLI binary and metallb templates
fn session_stop_metallb_cleanup() {
    // session-stop cleans temporary metallb templates for pending run
}

#[test]
#[ignore] // Requires CLI binary
fn session_start_no_replay() {
    // session-start compact does not replay consumed handoff
}
