// Tests for the audit hook.
// Verifies that audit is silent (allows) for both suite-runner and
// suite-author skills.

use harness::hooks::audit;

use super::super::helpers::*;

#[test]
fn audit_silent_runner() {
    let ctx = make_hook_context("suite-runner", make_bash_payload("echo hello"));
    let r = audit::execute(&ctx).unwrap();
    assert_allow(&r);
}

#[test]
fn audit_silent_author() {
    let ctx = make_hook_context("suite-author", make_bash_payload("echo hello"));
    let r = audit::execute(&ctx).unwrap();
    assert_allow(&r);
}
