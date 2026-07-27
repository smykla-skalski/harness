use std::path::Path;

use super::helpers::collect_hits_in_tree;

/// #766/#779/#797: `agents::service` used to decide for itself which hook
/// adapter should parse a raw payload, and reach into the same adapter
/// dispatch for an agent's display name. The one caller that needed the
/// parsed value, `agents::transport`'s dead `AgentsCommand` CLI surface, had
/// no real invocation path left once `crates/harness-hook` took over
/// `session-start`/`session-stop`/`prompt-submit` in production, so the fix
/// deleted that surface (and the now-uncallable `session_start`/
/// `session_stop`/`prompt_submit` functions with it) instead of relocating
/// the decision to another file still inside `src/agents/`. Scanning the
/// whole tree, not just `service.rs`, is what actually guards against that
/// relocation: a fix that only pinned one file would have missed the edge
/// reappearing in a sibling file within the same future `harness-agents`
/// crate boundary.
#[test]
fn agents_tree_stays_off_the_hook_adapter_dispatch() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_tree(
        &root.join("src/agents"),
        root,
        None,
        &["adapter_for("],
        |path, needle| format!("{path} reaches into the hook adapter dispatch via `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "agents:: should not decide how to parse a hook payload or resolve an agent's \
         adapter-owned name anywhere in the tree:\n{}",
        hits.join("\n")
    );
}
