// Tests for the verify-write and verify-question hooks.
// These post-tool-use hooks validate write results and question responses.

use harness::hooks::hook_result::Decision;
use harness::hooks::verify_question;

use super::super::helpers::*;

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
