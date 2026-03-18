// Tests for RunLayout and RunContext lifecycle types.
// Covers path construction, directory creation, round-trip recovery,
// and context loading from run directories.

use harness::run::{RunContext, RunLayout};
use harness::schema::Verdict;

use super::super::helpers::*;

// ============================================================================
// RunContext tests
// ============================================================================

#[test]
fn run_context_from_run_dir_loads_all_fields() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-ctx", "single-zone");
    let ctx = RunContext::from_run_dir(&run_dir).unwrap();
    assert_eq!(ctx.layout.run_id, "run-ctx");
    assert_eq!(ctx.metadata.suite_id, "example.suite");
    assert_eq!(ctx.metadata.profile, "single-zone");
    assert!(ctx.status.is_some());
    let status = ctx.status.unwrap();
    assert_eq!(status.overall_verdict, Verdict::Pending);
}

// ============================================================================
// RunLayout tests
// ============================================================================

#[test]
fn run_layout_paths_are_consistent() {
    let layout = RunLayout::new("/tmp/runs", "run-42");
    assert_eq!(layout.run_dir().to_string_lossy(), "/tmp/runs/run-42");
    assert_eq!(
        layout.artifacts_dir().to_string_lossy(),
        "/tmp/runs/run-42/artifacts"
    );
    assert_eq!(
        layout.commands_dir().to_string_lossy(),
        "/tmp/runs/run-42/commands"
    );
    assert_eq!(
        layout.manifests_dir().to_string_lossy(),
        "/tmp/runs/run-42/manifests"
    );
    assert_eq!(
        layout.state_dir().to_string_lossy(),
        "/tmp/runs/run-42/state"
    );
}

#[test]
fn run_layout_ensure_dirs_creates_all() {
    let tmp = tempfile::tempdir().unwrap();
    let layout = RunLayout::new(tmp.path().to_string_lossy().to_string(), "test-ensure");
    layout.ensure_dirs().unwrap();
    assert!(layout.run_dir().is_dir());
    assert!(layout.artifacts_dir().is_dir());
    assert!(layout.commands_dir().is_dir());
    assert!(layout.manifests_dir().is_dir());
    assert!(layout.state_dir().is_dir());
}
