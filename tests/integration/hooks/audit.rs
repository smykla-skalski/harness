// Tests for the audit hook.
// Verifies that audit is silent (allows) for both suite:run and
// suite:new skills.

use harness::hooks::audit;

use super::super::helpers::*;

#[test]
fn audit_silent_runner() {
    let ctx = make_hook_context("suite:run", make_bash_payload("echo hello"));
    let r = audit::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn audit_silent_author() {
    let ctx = make_hook_context("suite:new", make_bash_payload("echo hello"));
    let r = audit::execute(&ctx).unwrap();
    assert_allow(&r);
}
