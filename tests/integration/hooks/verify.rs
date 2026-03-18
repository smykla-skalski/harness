// Tests for verify-bash, verify-write, and verify-question hooks.
// These post-tool-use hooks validate command output, write results,
// and question responses.

use harness::hooks::hook_result::Decision;
use harness::hooks::{verify_bash, verify_question, verify_write};

use super::super::helpers::*;

// ============================================================================
// verify-bash tests
// ============================================================================

#[test]
fn verify_bash_allows_simple_command() {
    let ctx = make_hook_context("suite:run", make_bash_payload("echo hello"));
    let r = verify_bash::execute(&ctx).unwrap();
    assert!(r.decision == Decision::Allow || r.decision == Decision::Warn);
}

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

#[test]
fn verify_question_allows_simple() {
    let payload = make_question_payload("Do you want to continue?", &["Yes", "No"]);
    let ctx = make_hook_context("suite:run", payload);
    let r = verify_question::execute(&ctx).unwrap();
    assert!(r.decision == Decision::Allow || r.decision == Decision::Warn);
}
