// Tests for the guard-question hook.
// Verifies inactive skill bypass, empty prompt allowance, manifest-fix triage
// gating, and approval state requirements.

use harness::hooks::guard_question;
use harness::workflow::runner::{
    self as runner_workflow, FailureKind, FailureState, PreflightState, PreflightStatus,
    RunnerPhase, RunnerWorkflowState,
};

use super::super::helpers::*;

#[test]
fn guard_question_ignores_inactive_skill() {
    let payload = make_question_payload("Some question?", &["Yes", "No"]);
    let mut ctx = make_hook_context("suite:new", payload);
    ctx.skill_active = false;
    let r = guard_question::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_question_allows_empty_prompts() {
    let ctx = make_hook_context("suite:run", make_empty_payload());
    let r = guard_question::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_question_requires_triage() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let question = "suite:run/manifest-fix: how should this failure be handled?";
    let options = &[
        "Fix for this run only",
        "Fix in suite and this run",
        "Skip this step",
        "Stop run",
    ];
    let payload = make_question_payload(question, options);
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_question::execute(&ctx).unwrap();
    // Not in triage phase, so should deny
    assert_deny(&r);
}

#[test]
fn guard_question_allows_manifest_fix_in_triage() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    // Set runner state to triage with a failure
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
        suite_fix: None,
        updated_at: "2026-03-14T00:00:00Z".to_string(),
        transition_count: 3,
        last_event: Some("FailureRecorded".to_string()),
    };
    runner_workflow::write_runner_state(&run_dir, &state).unwrap();
    let question = "suite:run/manifest-fix: how should this failure be handled?";
    let options = &[
        "Fix for this run only",
        "Fix in suite and this run",
        "Skip this step",
        "Stop run",
    ];
    let payload = make_question_payload(question, options);
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = guard_question::execute(&ctx).unwrap();
    assert_allow(&r);
}
