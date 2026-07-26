// Tests for the guard-write hook.
// The suite:run write surface is retired, so guard-write now serves
// suite:create alone.

use harness::hooks::guard_write;

use super::super::helpers::*;

/// With no create state there is no suite surface to restrict writes to, so
/// even a path well outside the workspace is allowed through.
#[test]
fn guard_write_allows_external_path_without_create_state() {
    let ctx = make_hook_context("suite:create", make_write_payload("/etc/passwd"));
    let r = guard_write::execute(&ctx).unwrap();
    assert_allow(&r);
}
