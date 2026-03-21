// Tests for the audit hook.
// Verifies that audit is silent (allows) for both suite:run and
// suite:create skills.

use harness::hooks::audit;

use super::super::helpers::*;

#[test]
fn audit_silent_runner() {
    let ctx = make_hook_context("suite:run", make_bash_payload("echo hello"));
    let r = audit::execute(&ctx).unwrap().to_hook_result();
    assert_allow(&r);
}

#[test]
fn audit_silent_create() {
    let ctx = make_hook_context("suite:create", make_bash_payload("echo hello"));
    let r = audit::execute(&ctx).unwrap().to_hook_result();
    assert_allow(&r);
}
