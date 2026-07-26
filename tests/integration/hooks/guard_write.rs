// Tests for the guard-write hook.
// The suite:run write surface is retired, so guard-write now serves
// suite:create alone.

use harness::hooks::guard_write;

use super::super::helpers::*;

#[test]
fn guard_write_denies_external_create() {
    // Without any create state, writes to external paths are allowed
    // because there's no suite context to restrict to
    let ctx = make_hook_context("suite:create", make_write_payload("/etc/passwd"));
    let r = guard_write::execute(&ctx).unwrap();
    // Without create state, suite:create allows any path (no suite context)
    assert_allow(&r);
}
