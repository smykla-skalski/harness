use std::path::Path;

use super::helpers::collect_hits_in_tree;

/// `agents` may depend on `session` in exactly one direction: never. Only
/// `crates/harness-hooks/src/runtime/` legally spans both domains, and it is where the
/// hook-observed runtime session gets reconciled against orchestration
/// state. A `crate::session::` edge from inside `crates/harness-agents/src`
/// (which now holds the whole domain, `acp` included) would not even
/// compile, since `session` is not one of its dependencies; this guard
/// covers that tree as defense-in-depth against the same `crate::session::`
/// spelling reappearing, in case it ever gains a real `session` dependency of
/// its own.
#[test]
fn agents_tree_stays_off_session() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

    let hits = collect_hits_in_tree(
        &root.join("crates/harness-agents/src"),
        root,
        None,
        &["crate::session::"],
        |path, needle| format!("{path} reaches into session via `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "agents:: should depend on session:: only through the allowed hooks -> {{agents, \
         session}} direction in crates/harness-hooks/src/runtime/, never directly:\n{}",
        hits.join("\n")
    );
}
