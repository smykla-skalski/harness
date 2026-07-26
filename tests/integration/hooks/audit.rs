// Tests for the audit hook.
// Verifies that audit is silent (allows) for both suite:run and
// suite:create skills.

use harness::hooks::audit;

use super::super::helpers::*;

/// The retired suite:run skill never confirms, so audit records nothing and
/// allows rather than reaching the run-directory branch.
#[test]
fn audit_silent_for_retired_runner_skill() {
    let ctx = make_hook_context("suite:run", make_bash_payload("echo hello"));
    assert!(
        !ctx.skill_active,
        "the retired runner skill must not confirm the session"
    );
    let r = audit::execute(&ctx).unwrap().to_hook_result();
    assert_allow(&r);
}

#[test]
fn audit_silent_create() {
    let ctx = make_hook_context("suite:create", make_bash_payload("echo hello"));
    let r = audit::execute(&ctx).unwrap().to_hook_result();
    assert_allow(&r);
}
