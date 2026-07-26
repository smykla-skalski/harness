// Tests for the verify-write and verify-question hooks.
// These post-tool-use hooks validate write results and question responses.

use harness::hooks::hook_result::Decision;
use harness::hooks::{verify_question, verify_write};

use super::super::helpers::*;

// ============================================================================
// verify-write tests
// ============================================================================

#[test]
fn verify_write_allows_artifact() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let artifact_path = run_dir.join("artifacts").join("output.json");
    let payload = make_write_payload(&artifact_path.to_string_lossy());
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = verify_write::execute(&ctx).unwrap().to_hook_result();
    assert!(r.decision == Decision::Allow || r.decision == Decision::Warn);
}

#[test]
fn verify_write_denies_command_log() {
    let tmp = tempfile::tempdir().unwrap();
    let run_dir = init_run(tmp.path(), "run-1", "single-zone");
    let log_path = run_dir.join("commands").join("command-log.md");
    let payload = make_write_payload(&log_path.to_string_lossy());
    let ctx = make_hook_context_with_run("suite:run", payload, &run_dir);
    let r = verify_write::execute(&ctx).unwrap().to_hook_result();
    // verify-write should also deny control file edits
    assert!(r.decision == Decision::Deny || r.decision == Decision::Warn);
}

// ============================================================================
// verify-question tests
// ============================================================================

/// The retired suite:run skill never confirms, so verify-question stays inert
/// for it regardless of the answers carried in the payload.
#[test]
fn verify_question_ignores_retired_runner_skill() {
    let payload = make_question_payload("Do you want to continue?", &["Yes", "No"]);
    let ctx = make_hook_context("suite:run", payload);
    assert!(
        !ctx.skill_active,
        "the retired runner skill must not confirm the session"
    );
    let r = verify_question::execute(&ctx).unwrap();
    assert!(r.decision == Decision::Allow || r.decision == Decision::Warn);
}
