// Tests for the guard-question hook.
// Verifies inactive skill bypass, empty prompt allowance, and approval state
// requirements.

use super::super::helpers::*;
use harness::hooks::guard_question;

#[test]
fn guard_question_ignores_inactive_skill() {
    let payload = make_question_payload("Some question?", &["Yes", "No"]);
    let mut ctx = make_hook_context("suite:create", payload);
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
