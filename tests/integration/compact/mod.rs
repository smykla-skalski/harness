// Compact/fingerprint integration tests.
// Tests compact handoff lifecycle (build, save, consume, session start/stop).
//
// All env-dependent tests are combined into one #[test] to avoid races
// from parallel test execution mutating the same env vars (XDG_DATA_HOME,
// CLAUDE_SESSION_ID, HOME). See workspace tests for the same pattern.

use std::env;
use std::fs;
use std::path::Path;
use std::sync::PoisonError;

use harness::setup::{PreCompactArgs, SessionStartArgs, SessionStopArgs};
use harness::workspace::compact::{
    self, CreateHandoff, FileFingerprint, HandoffStatus, RunnerHandoff,
};

use super::helpers::*;

mod fingerprints;

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

// Build an create handoff for testing.
fn test_create() -> CreateHandoff<'static> {
    CreateHandoff {
        suite_dir: "/suites/s1".into(),
        next_action: "pre-write review loop".into(),
        create_phase: Some("prewrite_review".into()),
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

fn with_compact_env(session_id: &str, test: impl FnOnce(&Path)) {
    let _lock = ENV_LOCK.lock().unwrap_or_else(PoisonError::into_inner);
    let (xdg, project) = setup_env();
    let orig_path = env::var("PATH").unwrap_or_default();
    let path_with_bin = format!("{}:{orig_path}", xdg.path().join("bin").display());
    let xdg_str = xdg.path().to_str().unwrap();

    temp_env::with_vars(
        [
            ("XDG_DATA_HOME", Some(xdg_str)),
            ("CLAUDE_SESSION_ID", Some(session_id)),
            ("HOME", Some(xdg_str)),
            ("PATH", Some(path_with_bin.as_str())),
        ],
        || test(project.path()),
    );
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

// Attach an create section, save, reload, verify payloads.
fn check_build_compact_includes_create(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    handoff.create = Some(test_create());
    compact::save_compact_handoff(project, &handoff).expect("save");

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("should exist");
    assert!(loaded.has_sections());
    let auth = loaded.create.expect("create should be present");
    assert_eq!(auth.suite_name.as_deref(), Some("motb-core"));
    assert_eq!(auth.saved_payloads, vec!["inventory", "proposal"]);
}

// Create round-trips with mode/feature set.
fn check_build_compact_create_fallback(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    let mut auth = test_create();
    auth.mode = Some("bypass".into());
    auth.feature = Some("fallback-feature".into());
    handoff.create = Some(auth);
    compact::save_compact_handoff(project, &handoff).expect("save");

    let loaded = compact::load_latest_compact_handoff(project)
        .expect("load")
        .expect("should exist");
    let auth = loaded.create.expect("create present");
    assert_eq!(auth.mode.as_deref(), Some("bypass"));
    assert_eq!(auth.feature.as_deref(), Some("fallback-feature"));
}

// Save writes latest + history. Consume marks consumed.
fn check_save_consume_compact_handoff(project: &Path) {
    let handoff = compact::build_compact_handoff(project).expect("build");
    compact::save_compact_handoff(project, &handoff).expect("save");

    assert_compact_handoff_persisted(project);

    let pending = compact::pending_compact_handoff(project)
        .expect("load pending")
        .expect("should be pending");

    let consumed = compact::consume_compact_handoff(project, pending).expect("consume");
    assert_eq!(consumed.status, HandoffStatus::Consumed);
    assert!(consumed.consumed_at.is_some());

    let after = compact::pending_compact_handoff(project).expect("load consumed");
    assert!(after.is_none(), "should not be pending after consume");

    assert_compact_handoff_consumed(project);
}

fn assert_compact_handoff_persisted(project: &Path) {
    let latest = compact::compact_latest_path(project);
    assert!(latest.exists(), "latest.json should exist");

    let history_dir = compact::compact_project_dir(project).join("history");
    assert!(history_dir.is_dir(), "history dir should exist");
    let history_count = fs::read_dir(&history_dir).unwrap().count();
    assert!(history_count >= 1, "should have at least 1 history entry");
}

fn assert_compact_handoff_consumed(project: &Path) {
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

    let pending = compact::pending_compact_handoff(project).expect("load consumed");
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

    let pending = compact::pending_compact_handoff(project)
        .expect("load pending")
        .expect("should be pending");
    let diverged = compact::verify_fingerprints(&pending);
    let ctx = compact::render_hydration_context(&pending, &diverged);
    assert!(
        ctx.contains("harness run resume"),
        "should include resume guidance: {ctx}"
    );

    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());

    let after = compact::pending_compact_handoff(project).expect("load consumed");
    assert!(after.is_none());
}

// Save handoff with create, verify hydration context
//includes create details, session-start consumes it.
fn check_session_start_compact_restores_create(project: &Path) {
    let mut handoff = compact::build_compact_handoff(project).expect("build");
    handoff.create = Some(test_create());
    compact::save_compact_handoff(project, &handoff).expect("save");

    let pending = compact::pending_compact_handoff(project)
        .expect("load pending")
        .expect("should be pending");
    let ctx = compact::render_hydration_context(&pending, &[]);
    assert!(ctx.contains("suite:create:"), "should have create section");
    assert!(ctx.contains("motb-core"), "should mention suite name");

    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());

    let after = compact::pending_compact_handoff(project).expect("load consumed");
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

    let pending = compact::pending_compact_handoff(project).expect("load pending");
    assert!(
        pending.is_some(),
        "handoff should be pending for same project"
    );

    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());

    let after = compact::pending_compact_handoff(project).expect("load consumed");
    assert!(after.is_none(), "should be consumed");
}

// No pending handoff - session-start returns Ok(0).
fn check_session_start_without_pending_handoff(project: &Path) {
    let result = session_start_cmd(SessionStartArgs {
        project_dir: Some(project.to_string_lossy().to_string()),
    })
    .execute();
    assert!(result.is_ok());
    assert_eq!(result.unwrap(), 0);
}

// With no current-run pointer, session-stop returns Ok(0).
fn check_session_stop_without_pointer(project: &Path) {
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

    let pending = compact::pending_compact_handoff(project)
        .expect("load pending")
        .expect("should be pending");
    let _ = compact::consume_compact_handoff(project, pending).expect("consume");

    let after = compact::pending_compact_handoff(project).expect("load consumed");
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
fn compact_runner_handoff_roundtrip_smoke() {
    with_compact_env(
        "compact-runner-roundtrip",
        check_build_compact_includes_runner,
    );
}

#[test]
#[ignore = "slow: spawns fake toolchain processes"]
fn compact_handoff_lifecycle() {
    with_compact_env("compact-lifecycle", |project| {
        check_build_compact_includes_runner(project);
        check_build_compact_worktree_project(project);
        check_build_compact_includes_create(project);
        check_build_compact_create_fallback(project);
        check_save_consume_compact_handoff(project);
        check_pre_compact_persists(project);
        check_session_start_compact_hydrates(project);
        check_session_start_compact_worktree(project);
        check_session_start_compact_aborted_resume(project);
        check_session_start_compact_restores_create(project);
        check_session_start_compact_divergence_warning(project);
        check_session_start_restores_project(project);
        check_session_start_restores_worktree(project);
        check_session_start_cross_project(project);
        check_session_start_without_pending_handoff(project);
        check_session_stop_without_pointer(project);
        check_session_start_no_replay(project);
    });
}
