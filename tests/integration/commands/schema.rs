// Tests for suite and group spec parsing from markdown frontmatter.
// Covers SuiteSpec and GroupSpec loading, validation of required fields
// and sections, MeshMetric group handling, and RunStatus serialization.

use std::fs;

use harness::schema::{GroupSpec, RunCounts, RunStatus, SuiteSpec, Verdict};

use super::super::helpers::*;

// ============================================================================
// SuiteSpec loading tests
// ============================================================================

#[test]
fn suite_spec_loads_from_valid_markdown() {
    let tmp = tempfile::tempdir().unwrap();
    let suite_path = tmp.path().join("suite.md");
    write_suite(&suite_path);
    let spec = SuiteSpec::from_markdown(&suite_path).unwrap();
    assert_eq!(spec.frontmatter.suite_id, "example.suite");
    assert_eq!(spec.frontmatter.feature, "example");
    assert_eq!(spec.frontmatter.groups, vec!["groups/g01.md"]);
    assert!(!spec.frontmatter.keep_clusters);
}

#[test]
fn suite_spec_rejects_missing_frontmatter() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("no-fm.md");
    fs::write(&path, "# Just a heading\n\nSome body.\n").unwrap();
    let err = SuiteSpec::from_markdown(&path).unwrap_err();
    assert!(
        err.message().contains("frontmatter"),
        "error: {}",
        err.message()
    );
}

#[test]
fn suite_spec_rejects_missing_fields() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("partial.md");
    // Minimal suite with only suite_id - missing feature, scope, keep_clusters
    fs::write(&path, "---\nsuite_id: x\n---\n\nBody.\n").unwrap();
    let err = SuiteSpec::from_markdown(&path).unwrap_err();
    assert!(
        err.message().contains("missing"),
        "error: {}",
        err.message()
    );
}

// ============================================================================
// GroupSpec loading tests
// ============================================================================

#[test]
fn group_spec_loads_from_valid_markdown() {
    let tmp = tempfile::tempdir().unwrap();
    let group_path = tmp.path().join("g01.md");
    write_group(&group_path);
    let spec = GroupSpec::from_markdown(&group_path).unwrap();
    assert_eq!(spec.frontmatter.group_id, "g01");
    assert_eq!(spec.frontmatter.story, "example story");
    assert!(spec.body.contains("## Configure"));
    assert!(spec.body.contains("## Consume"));
    assert!(spec.body.contains("## Debug"));
}

#[test]
fn group_spec_rejects_missing_sections() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("bad-group.md");
    // Group with only Configure - missing Consume and Debug sections
    fs::write(
        &path,
        "---\ngroup_id: g01\nstory: test\n---\n\n## Configure\n\nOnly one section.\n",
    )
    .unwrap();
    let err = GroupSpec::from_markdown(&path).unwrap_err();
    assert!(
        err.message().contains("missing"),
        "error: {}",
        err.message()
    );
}

// ============================================================================
// MeshMetric group tests
// ============================================================================

#[test]
fn meshmetric_group_loads_valid() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("g01.md");
    write_meshmetric_group(&path, false);
    let spec = GroupSpec::from_markdown(&path).unwrap();
    assert_eq!(spec.frontmatter.group_id, "g01");
    assert!(spec.body.contains("MeshMetric"));
    assert!(!spec.body.contains("backendRef"));
}

#[test]
fn meshmetric_group_with_invalid_backend_ref() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("g01.md");
    write_meshmetric_group(&path, true);
    let spec = GroupSpec::from_markdown(&path).unwrap();
    assert!(spec.body.contains("backendRef"));
}

// ============================================================================
// RunStatus tests
// ============================================================================

#[test]
fn run_status_load_and_parse() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-status-test", "single-zone");
    let status = read_run_status(&run_dir);
    assert_eq!(status.overall_verdict, Verdict::Pending);
    assert_eq!(status.run_id, "run-status-test");
    assert!(status.notes.is_empty());
}

#[test]
fn run_status_write_and_reload() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-status-rw", "single-zone");
    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    status.notes.push("test note".to_string());
    write_run_status(&run_dir, &status);
    let reloaded = read_run_status(&run_dir);
    assert_eq!(reloaded.overall_verdict, Verdict::Pass);
    assert_eq!(reloaded.notes, vec!["test note"]);
}

#[test]
fn run_status_executed_group_ids() {
    let status = RunStatus {
        run_id: "t".to_string(),
        suite_id: "s".to_string(),
        profile: "single-zone".to_string(),
        started_at: "now".to_string(),
        overall_verdict: Verdict::Pending,
        completed_at: None,
        counts: RunCounts::default(),
        executed_groups: vec![
            serde_json::Value::String("g01".to_string()),
            serde_json::json!({"group_id": "g02", "verdict": "pass"}),
        ],
        skipped_groups: vec![],
        last_completed_group: None,
        last_state_capture: None,
        last_updated_utc: None,
        next_planned_group: None,
        notes: vec![],
    };
    assert_eq!(status.executed_group_ids(), vec!["g01", "g02"]);
}
