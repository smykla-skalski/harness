use std::path::Path;

use super::helpers::collect_hits_in_tree;

/// `agents` may depend on `session` in exactly one direction: never. Only
/// `src/hooks/runtime/` legally spans both domains, and it is where the
/// hook-observed runtime session gets reconciled against orchestration
/// state. A `crate::session::` edge from inside `crates/harness-agents/src`
/// would not even compile, since `session` is not one of its dependencies;
/// this guard instead covers `src/agents` (the `acp` subtree that stays in
/// the root crate for now) plus a defense-in-depth scan of
/// `crates/harness-agents/src` against the same `crate::session::` spelling,
/// in case that crate ever gains a real `session` dependency of its own.
///
/// `src/agents/kind/disconnect.rs` is the one expected survivor, for the same
/// reason `src/agents/kind/mod.rs` is exempt in the sibling
/// `hooks_agents_session_boundary` guard: it is a `mod disconnect;` child of
/// `kind/mod.rs`, and root's own `agents::kind` is an inline re-export shim
/// (`pub use harness_agents::*;` in `src/lib.rs`, itself re-exporting
/// `harness-agents`'s own `pub mod kind { pub use harness_protocol::agent::...; }`)
/// rather than `mod kind;` pointing at these files, so neither file is part
/// of root's own build; only `harness_protocol` pulls them in with `#[path]`.
/// Its doc comment names `crate::session::types::AgentStatus::Disconnected`
/// as an intra-doc link describing the status this reason accompanies, not a
/// compiled dependency edge.
#[test]
fn agents_tree_stays_off_session() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let known_exceptions = ["src/agents/kind/disconnect.rs"];

    let mut hits = collect_hits_in_tree(
        &root.join("src/agents"),
        root,
        None,
        &["crate::session::"],
        |path, needle| format!("{path} reaches into session via `{needle}`"),
    );
    hits.extend(collect_hits_in_tree(
        &root.join("crates/harness-agents/src"),
        root,
        None,
        &["crate::session::"],
        |path, needle| format!("{path} reaches into session via `{needle}`"),
    ));

    hits.retain(|hit| !known_exceptions.iter().any(|known| hit.starts_with(known)));

    assert!(
        hits.is_empty(),
        "agents:: should depend on session:: only through the allowed hooks -> {{agents, \
         session}} direction in src/hooks/runtime/, never directly:\n{}",
        hits.join("\n")
    );
}
