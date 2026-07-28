use std::path::Path;

use super::helpers::collect_hits_in_tree;

/// `agents::transport`'s `AgentsCommand` CLI surface was the only caller
/// that needed a parsed hook payload, and `crates/harness-hook` owns
/// `session-start`/`session-stop`/`prompt-submit` in production, so nothing
/// in `src/agents/` should decide which hook adapter parses a payload or
/// looks up an agent's adapter-owned display name. Scanning the whole tree,
/// not just `service.rs`, is what actually guards against that: pinning one
/// file would miss the edge reappearing in a sibling file within the same
/// future `harness-agents` crate boundary.
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
