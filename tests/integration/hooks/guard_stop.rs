// Tests for the guard-stop hook.
// Verifies session termination blocking based on run state: pending closeout
// denial, aborted run allowance, verdict+capture requirements, and inactive
// skill bypass.

use harness::hooks::guard_stop;
use harness::schema::Verdict;

use super::super::helpers::*;

#[test]
fn guard_stop_retires_active_skill() {
    let mut ctx = make_hook_context("suite-runner", make_stop_payload());
    ctx.skill_active = false;
    let r = guard_stop::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_stop_denies_pending_closeout() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let payload = make_stop_payload();
    let ctx = make_hook_context_with_run("suite-runner", payload, &run_dir);
    let r = guard_stop::execute(&ctx).unwrap();
    // Pending verdict should be denied
    assert_deny(&r);
}

#[test]
fn guard_stop_allows_aborted() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    // Update status to aborted with state capture
    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Aborted;
    status.last_state_capture = Some("state/capture.json".to_string());
    write_run_status(&run_dir, &status);
    let payload = make_stop_payload();
    let ctx = make_hook_context_with_run("suite-runner", payload, &run_dir);
    let r = guard_stop::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_stop_denies_no_state_capture() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    // Set verdict but no state capture
    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    status.last_state_capture = None;
    write_run_status(&run_dir, &status);
    let payload = make_stop_payload();
    let ctx = make_hook_context_with_run("suite-runner", payload, &run_dir);
    let r = guard_stop::execute(&ctx).unwrap();
    assert_deny(&r);
}

#[test]
fn guard_stop_allows_with_verdict_and_capture() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let mut status = read_run_status(&run_dir);
    status.overall_verdict = Verdict::Pass;
    status.last_state_capture = Some("state/capture.json".to_string());
    write_run_status(&run_dir, &status);
    let payload = make_stop_payload();
    let ctx = make_hook_context_with_run("suite-runner", payload, &run_dir);
    let r = guard_stop::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn guard_stop_allows_inactive() {
    let ctx = make_hook_context("suite-runner", make_stop_payload());
    // Without a run context, guard-stop allows (no run to protect)
    let r = guard_stop::execute(&ctx).unwrap();
    assert_allow(&r);
}
