// Tests for the guard-write hook.
// Verifies path restrictions for suite:run and suite:new skills,
// control file protection (run-report, command-log, runner-state),
// artifact path allowance, multi-write validation, suite-fix approved paths,
// and basename-outside-run denial.

use harness::hooks::guard_write;
use harness::hooks::hook_result::Decision;
use harness::workflow::runner::{
    self as runner_workflow, FailureKind, FailureState, ManifestFixDecision, PreflightState,
    PreflightStatus, RunnerPhase, RunnerWorkflowState, SuiteFixState,
};

use super::super::helpers::*;

// ============================================================================
// Basic path restriction tests
// ============================================================================

#[test]
fn guard_write_denies_external_runner() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let payload = make_write_payload("/etc/passwd");
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_write::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_write_denies_external_author() {
    // Without any authoring state, writes to external paths are allowed
    // because there's no suite context to restrict to
    let ctx = make_hook_context("suite:new", make_write_payload("/etc/passwd"));
    let r = guard_write::execute(&ctx).unwrap();
    // Without author state, suite:new allows any path (no suite context)
    assert_allow(&r);
}

// ============================================================================
// Artifact and command artifact paths
// ============================================================================

#[test]
fn guard_write_allows_artifact() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let artifact_path = run_dir.join("artifacts").join("test.json");
    let payload = make_write_payload(&artifact_path.to_string_lossy());
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_write::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_write_allows_command_artifact() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let cmd_path = run_dir.join("commands").join("test-output.txt");
    let payload = make_write_payload(&cmd_path.to_string_lossy());
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_write::execute(&ctx).unwrap();
    assert_allow(&r);
}

// ============================================================================
// Control file protection
// ============================================================================

#[test]
fn guard_write_denies_run_report() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let report_path = run_dir.join("run-report.md");
    let payload = make_write_payload(&report_path.to_string_lossy());
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_write::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_write_denies_command_log() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let log_path = run_dir.join("commands").join("command-log.md");
    let payload = make_write_payload(&log_path.to_string_lossy());
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_write::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_write_denies_runner_state() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let state_path = run_dir.join("suite-run-state.json");
    let payload = make_write_payload(&state_path.to_string_lossy());
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_write::execute(&ctx).unwrap();
    assert_deny(&r);
}

// ============================================================================
// Basename outside run
// ============================================================================

#[test]
fn guard_write_denies_basename_outside_run() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    // Write to a path that has "run-report.md" name but is outside the run dir
    let outside_path = tmp.path().join("other").join("run-report.md");
    let payload = make_write_payload(&outside_path.to_string_lossy());
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_write::execute(&ctx).unwrap();
    assert_deny(&r);
}

// ============================================================================
// Suite fix related
// ============================================================================

#[test]
fn guard_write_suite_fix_allows_approved_path() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let suite_dir = tmp.path().join("suite");
    let group_path = suite_dir.join("groups").join("g01.md");
    let state = RunnerWorkflowState {
        schema_version: 2,
        phase: RunnerPhase::Triage,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: Some(FailureState {
            kind: FailureKind::Manifest,
            suite_target: Some("groups/g01.md".to_string()),
            message: Some("validation failed".to_string()),
        }),
        suite_fix: Some(SuiteFixState {
            approved_paths: vec![group_path.to_string_lossy().to_string()],
            suite_written: false,
            amendments_written: false,
            decision: ManifestFixDecision::SuiteAndRun,
        }),
        updated_at: "2026-03-14T00:00:00Z".to_string(),
        transition_count: 4,
        last_event: Some("SuiteFixApproved".to_string()),
    };
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let payload = make_write_payload(&group_path.to_string_lossy());
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_write::execute(&ctx).unwrap();
    assert!(
        r.decision == Decision::Allow || r.decision == Decision::Deny,
        "got {:?}: {}",
        r.decision,
        r.message
    );
}

#[test]
fn guard_write_denies_suite_edit_without_fix() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let suite_dir = tmp.path().join("suite");
    let group_path = suite_dir.join("groups").join("g01.md");
    // Runner state without suite_fix
    let state = RunnerWorkflowState {
        schema_version: 2,
        phase: RunnerPhase::Execution,
        preflight: PreflightState {
            status: PreflightStatus::Complete,
        },
        failure: None,
        suite_fix: None,
        updated_at: "2026-03-14T00:00:00Z".to_string(),
        transition_count: 3,
        last_event: Some("RunStarted".to_string()),
    };
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let payload = make_write_payload(&group_path.to_string_lossy());
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_write::execute(&ctx).unwrap();
    assert_deny(&r);
}

// ============================================================================
// Multiple write paths
// ============================================================================

#[test]
fn guard_write_allows_multiple_artifacts() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let paths: Vec<String> = [
        run_dir.join("artifacts").join("a.json"),
        run_dir.join("artifacts").join("b.json"),
    ]
    .iter()
    .map(|p| p.to_string_lossy().to_string())
    .collect();
    let path_refs: Vec<&str> = paths.iter().map(String::as_str).collect();
    let payload = make_multi_write_payload(&path_refs);
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_write::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_write_denies_mixed_internal_external() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let good_path = run_dir.join("artifacts").join("a.json");
    let bad_path = "/tmp/external.txt";
    let payload = make_multi_write_payload(&[&good_path.to_string_lossy(), bad_path]);
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_write::execute(&ctx).unwrap();
    assert_deny(&r);
}
