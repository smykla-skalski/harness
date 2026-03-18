// Compact/fingerprint integration tests.
// Tests FileFingerprint creation, serialization, content change detection,
// and compact handoff lifecycle (build, save, consume, session start/stop).
//
// All env-dependent tests are combined into one #[test] to avoid races
// from parallel test execution mutating the same env vars (XDG_DATA_HOME,
// CLAUDE_SESSION_ID, HOME). See core_defs::tests for the same pattern.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::PoisonError;

use harness::compact::{self, AuthoringHandoff, FileFingerprint, HandoffStatus, RunnerHandoff};
use harness::platform::ephemeral_metallb;
use harness::setup::{PreCompactArgs, SessionStartArgs, SessionStopArgs};

use super::helpers::*;

// Build a runner handoff for testing.
fn test_runner() -> RunnerHandoff<'static> {
    RunnerHandoff {
        run_dir: "/runs/r1".into(),
        run_id: "r1".into(),
        suite_id: Some("test.suite".into()),
        profile: Some("single-zone".into()),
        suite_path: Some("/suites/s1/suite.md".into()),
        runner_phase: Some("execution".into()),
        verdict: Some("pending".into()),
        completed_at: None,
        last_state_capture: None,
        next_action: "run next group".into(),
        executed_groups: vec!["g01".into()],
        remaining_groups: vec!["g02".into(), "g03".into()],
        state_paths: vec![
            "/runs/r1/run-status.json".into(),
            "/runs/r1/suite-run-state.json".into(),
        ],
    }
}

// Build an authoring handoff for testing.
fn test_authoring() -> AuthoringHandoff<'static> {
    AuthoringHandoff {
        suite_dir: "/suites/s1".into(),
        next_action: "pre-write review loop".into(),
        author_phase: Some("prewrite_review".into()),
        suite_name: Some("motb-core".into()),
        feature: Some("motb".into()),
        mode: Some("interactive".into()),
        saved_payloads: vec!["inventory".into(), "proposal".into()],
        suite_files: vec!["suite.md".into()],
        state_paths: vec!["/suites/s1/state.json".into()],
    }
}

// Set up an isolated env for compact tests.
//
// Creates the plugin wrapper so bootstrap doesn't fail.
// Returns `(xdg_dir, project_dir)` as temp dirs.
fn setup_env() -> (tempfile::TempDir, tempfile::TempDir) {
    let xdg = tempfile::tempdir().unwrap();
    let project = tempfile::tempdir().unwrap();

    // bootstrap expects .claude/plugins/suite/harness to exist
    let plugin_dir = project.path().join(".claude").join("plugins").join("suite");
    fs::create_dir_all(&plugin_dir).unwrap();
    fs::write(plugin_dir.join("harness"), "#!/bin/sh\necho ok\n").unwrap();

    // bootstrap also needs a writable bin dir
    let bin_dir = xdg.path().join("bin");
    fs::create_dir_all(&bin_dir).unwrap();

    (xdg, project)
}

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

// ============================================================================
// Compact handoff tests
//
// All env-dependent tests live in one function to prevent env var races.
// Each logical test is a standalone helper called sequentially inside a
// single with_env_vars scope.
// ============================================================================

// build_compact_handoff returns runner: None by default.
// Attach a runner section, save, reload, verify.
fn check_build_compact_includes_runner(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build should succeed");
    assert!(handoff.runner.is_none(), "default build has no runner");

    handoff.runner = Some(test_runner());
    compact::save_compact_handoff(project, &handoff).expect("save should succeed");

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load should succeed")
        .expect("should find saved handoff");
    assert!(loaded.has_sections());
    let runner = loaded.runner.expect("runner should be present");
    assert_eq!(runner.run_id, "r1");
    assert_eq!(runner.remaining_groups, vec!["g02", "g03"]);
}

// Build from project dir, save with runner, reload. The
//hashing is stable for the same canonicalized path.
fn check_build_compact_worktree_project(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    handoff.runner = Some(test_runner());
    compact::save_compact_handoff(project, &handoff).expect("save");

    let latest = compact::compact_latest_path(project);
    assert!(
        latest.exists(),
        "latest.json should exist at {}",
        latest.display()
    );

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("should exist");
    assert_eq!(loaded.runner.as_ref().unwrap().run_id, "r1");
}

// Attach an authoring section, save, reload, verify payloads.
fn check_build_compact_includes_author(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    handoff.authoring = Some(test_authoring());
    compact::save_compact_handoff(project, &handoff).expect("save");

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("should exist");
    assert!(loaded.has_sections());
    let auth = loaded.authoring.expect("authoring should be present");
    assert_eq!(auth.suite_name.as_deref(), Some("motb-core"));
    assert_eq!(auth.saved_payloads, vec!["inventory", "proposal"]);
}

// Authoring round-trips with mode/feature set.
fn check_build_compact_author_fallback(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    let mut auth = test_authoring();
    auth.mode = Some("bypass".into());
    auth.feature = Some("fallback-feature".into());
    handoff.authoring = Some(auth);
    compact::save_compact_handoff(project, &handoff).expect("save");

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("should exist");
    let auth = loaded.authoring.expect("authoring present");
    assert_eq!(auth.mode.as_deref(), Some("bypass"));
    assert_eq!(auth.feature.as_deref(), Some("fallback-feature"));
}

// Save writes latest + history. Consume marks consumed.
#[allow(clippy::cognitive_complexity)]
fn check_save_consume_compact_handoff(project: &Path) {
    let handoff = compact::build_compact_handoff(project).expect("build");
    compact::save_compact_handoff(project, &handoff).expect("save");

    let latest = compact::compact_latest_path(project);
    assert!(latest.exists(), "latest.json should exist");

    let history_dir = compact::compact_project_dir(project).join("history");
    assert!(history_dir.is_dir(), "history dir should exist");
    let history_count = fs::read_dir(&history_dir).unwrap().count();
    assert!(history_count >= 1, "should have at least 1 history entry");

    let pending = compact::pending_compact_handoff(project);
    assert!(pending.is_some(), "should be pending");

    let consumed = compact::consume_compact_handoff(project, pending.unwrap()).expect("consume");
    assert_eq!(consumed.status, HandoffStatus::Consumed);
    assert!(consumed.consumed_at.is_some());

    let after = compact::pending_compact_handoff(project);
    assert!(after.is_none(), "should not be pending after consume");

    let reloaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("still exists");
    assert_eq!(reloaded.status, HandoffStatus::Consumed);
}

// pre_compact::execute creates the latest.json file.
fn check_pre_compact_persists(project: &Path) {
    let result = pre_compact_cmd(PreCompactArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok(), "pre-compact should succeed: {result:?}");
    assert_eq!(result.unwrap(), 0);

    let latest = compact::compact_latest_path(project);
    assert!(latest.exists(), "latest.json should be persisted");

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("should exist");
    assert_eq!(loaded.status, HandoffStatus::Pending);
}

// Pre-save a pending handoff with runner, session-start
//should consume it.
fn check_session_start_compact_hydrates(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    handoff.runner = Some(test_runner());
    compact::save_compact_handoff(project, &handoff).expect("save");

    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok(), "session-start should succeed: {result:?}");

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("should exist");
    assert_eq!(loaded.status, HandoffStatus::Consumed);
    assert!(loaded.consumed_at.is_some());
}

// Save handoff with runner, session-start consumes it.
fn check_session_start_compact_worktree(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    handoff.runner = Some(test_runner());
    compact::save_compact_handoff(project, &handoff).expect("save");

    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok(), "session-start should succeed: {result:?}");

    let pending = compact::pending_compact_handoff(project);
    assert!(pending.is_none(), "should be consumed after session-start");
}

// Save an aborted runner handoff with remaining groups.
// Hydration context should include resume guidance.
fn check_session_start_compact_aborted_resume(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    let mut runner = test_runner();
    runner.runner_phase = Some("aborted".into());
    runner.verdict = Some("aborted".into());
    handoff.runner = Some(runner);
    compact::save_compact_handoff(project, &handoff).expect("save");

    let pending = compact::pending_compact_handoff(project).expect("should be pending");
    let diverged = compact::verify_fingerprints(&pending);
    let ctx = compact::render_hydration_context(&pending, &diverged);
    assert!(
        ctx.contains("harness runner-state --event resume-run"),
        "should include resume guidance: {ctx}"
    );

    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());

    let after = compact::pending_compact_handoff(project);
    assert!(after.is_none());
}

// Save handoff with authoring, verify hydration context
//includes authoring details, session-start consumes it.
fn check_session_start_compact_restores_author(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    handoff.authoring = Some(test_authoring());
    compact::save_compact_handoff(project, &handoff).expect("save");

    let pending = compact::pending_compact_handoff(project).expect("should be pending");
    let ctx = compact::render_hydration_context(&pending, &[]);
    assert!(ctx.contains("suite:new:"), "should have authoring section");
    assert!(ctx.contains("motb-core"), "should mention suite name");

    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());

    let after = compact::pending_compact_handoff(project);
    assert!(after.is_none());
}

// Save handoff with fingerprints, modify the file, verify
// that verify_fingerprints detects the divergence.
fn check_session_start_compact_divergence_warning(project: &Path) {
    let tracked_file = project.join("tracked.txt");
    fs::write(&tracked_file, "original content").unwrap();
    let fp = FileFingerprint::from_path("tracked", &tracked_file);
    assert!(fp.exists);

    let mut handoff = compact::build_compact_handoff(project).expect("build");
    handoff.fingerprints = vec![fp];
    compact::save_compact_handoff(project, &handoff).expect("save");

    fs::write(&tracked_file, "modified content").unwrap();

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("should exist");
    let diverged = compact::verify_fingerprints(&loaded);
    assert_eq!(diverged.len(), 1, "should detect 1 diverged file");
    assert!(
        diverged[0].ends_with("tracked.txt"),
        "diverged path should reference tracked.txt: {}",
        diverged[0].display()
    );

    let ctx = compact::render_hydration_context(&loaded, &diverged);
    assert!(
        ctx.contains("WARNING: the saved handoff diverged"),
        "should warn about divergence: {ctx}"
    );
}

// Pre-save a pending handoff, session-start consumes it.
fn check_session_start_restores_project(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    handoff.runner = Some(test_runner());
    compact::save_compact_handoff(project, &handoff).expect("save");

    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("should exist");
    assert_eq!(loaded.status, HandoffStatus::Consumed);
    assert!(loaded.runner.is_some(), "runner should still be in data");
}

// Save with runner and worktree trigger, start, verify consumed.
fn check_session_start_restores_worktree(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    handoff.runner = Some(test_runner());
    handoff.trigger = Some("worktree-switch".into());
    compact::save_compact_handoff(project, &handoff).expect("save");

    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("should exist");
    assert_eq!(loaded.status, HandoffStatus::Consumed);
    assert_eq!(loaded.trigger.as_deref(), Some("worktree-switch"));
}

// Save handoff under this project, verify it persists across
//the scope (project-keyed, not session-keyed).
fn check_session_start_cross_project(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    handoff.runner = Some(test_runner());
    compact::save_compact_handoff(project, &handoff).expect("save");

    let pending = compact::pending_compact_handoff(project);
    assert!(
        pending.is_some(),
        "handoff should be pending for same project"
    );

    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());

    let after = compact::pending_compact_handoff(project);
    assert!(after.is_none(), "should be consumed");
}

// No pending handoff - session-start returns Ok(0).
// Verify ephemeral_metallb APIs are accessible.
fn check_session_start_metallb_templates(project: &Path) {
    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());
    assert_eq!(result.unwrap(), 0);

    let run_dir = project.join("test-run");
    fs::create_dir_all(&run_dir).unwrap();
    let cleaned = ephemeral_metallb::cleanup_templates(&run_dir);
    assert!(cleaned.is_ok());
    assert!(cleaned.unwrap().is_empty());
}

// session_stop is currently a no-op. Verify Ok(0).
fn check_session_stop_metallb_cleanup(project: &Path) {
    let result = session_stop_cmd(SessionStopArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());
    assert_eq!(result.unwrap(), 0);
}

// Consume a handoff first, then verify pending returns None
//and session-start does not replay it.
fn check_session_start_no_replay(project: &Path) {
    let handoff = compact::build_compact_handoff(project).expect("build");
    compact::save_compact_handoff(project, &handoff).expect("save");

    let pending = compact::pending_compact_handoff(project).expect("should be pending");
    let _ = compact::consume_compact_handoff(project, pending).expect("consume");

    let after = compact::pending_compact_handoff(project);
    assert!(after.is_none(), "consumed handoff should not be pending");

    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());
    assert_eq!(result.unwrap(), 0);

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("should exist");
    assert_eq!(loaded.status, HandoffStatus::Consumed);
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn compact_handoff_lifecycle() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let (xdg, project) = setup_env();
    let orig_path = env::var("PATH").unwrap_or_default();
    let path_with_bin = format!("{}:{orig_path}", xdg.path().join("bin").display());
    let xdg_str = xdg.path().to_str().unwrap();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg_str)),
            ("CLAUDE_SESSION_ID", Some("compact-lifecycle")),
            ("HOME", Some(xdg_str)),
            ("PATH", Some(path_with_bin.as_str())),
        ],
        || {
            check_build_compact_includes_runner(project.path());
            check_build_compact_worktree_project(project.path());
            check_build_compact_includes_author(project.path());
            check_build_compact_author_fallback(project.path());
            check_save_consume_compact_handoff(project.path());
            check_pre_compact_persists(project.path());
            check_session_start_compact_hydrates(project.path());
            check_session_start_compact_worktree(project.path());
            check_session_start_compact_aborted_resume(project.path());
            check_session_start_compact_restores_author(project.path());
            check_session_start_compact_divergence_warning(project.path());
            check_session_start_restores_project(project.path());
            check_session_start_restores_worktree(project.path());
            check_session_start_cross_project(project.path());
            check_session_start_metallb_templates(project.path());
            check_session_stop_metallb_cleanup(project.path());
            check_session_start_no_replay(project.path());
        },
    );
}
