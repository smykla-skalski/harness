use std::path::Path;

use super::helpers::collect_hits_in_tree;

/// `hooks` may depend on `session` and `agents` - `hooks::runtime` genuinely
/// needs `agents::runtime` for pending-signal pickup and
/// `agents::service`/`session::service` to record what happened and resolve a
/// runtime session - but nothing under `crates/harness-agents/src`,
/// `src/session`, `crates/harness-session/src`, or `src/task_board` may reach
/// back into `crate::hooks`; a real edge in that direction would block ever
/// giving any of those domains its own crate (`harness-agents` and
/// `harness-session` already are ones, and could not depend on the root
/// crate's `hooks` module even by accident: no such module exists from
/// inside either). `task_board` is scanned alongside the others because
/// it sits in the same daemon-facade layer and would hide the same kind of
/// edge reappearing there instead. Every current hit in this scan is
/// a type-only import of `HookAgent`, `NormalizedEvent`/`NormalizedHookContext`,
/// or `NormalizedHookResult` through the `crate::hooks::adapters`/
/// `crate::hooks::protocol` re-export shims; the canonical definitions live in
/// `harness_protocol`/`harness_kernel`, so every call site imports from there
/// directly instead.
///
/// `src/session/types/agent_tests.rs` is the one expected survivor. Root's own
/// `session::types` is an inline re-export module
/// (`pub mod types { pub use harness_protocol::session::*; }` in
/// `src/session/mod.rs`) rather than `mod types;` pointing at this file, so it
/// is not part of root's own build: `harness-protocol` pulls it in verbatim
/// with `#[path]` (`session/types/mod.rs` - and everything it `mod`-declares,
/// `agent_tests` included - to back the `session` module) to give those types
/// a single physical definition, mirroring how `harness-daemon`,
/// `harness-bridge`, and `harness-hook` already share other root files the
/// same way. Its `HookAgent` references have to stay on the
/// `crate::hooks::adapters::HookAgent` shim every one of those `#[path]` hosts
/// already provides, because a crate cannot name itself in a `use` path -
/// `harness_protocol::agent::HookAgent`, the direct import every other call
/// site in this scan now uses, does not resolve when the file is compiled as
/// part of `harness-protocol` itself (confirmed with a throwaway edit against
/// `cargo check -p harness-protocol`). Those references never leave
/// `harness-protocol`'s own compilation, so they are not real cross-crate
/// edges.
#[test]
fn agents_and_session_stay_off_the_hooks_module() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let known_exceptions = ["src/session/types/agent_tests.rs"];

    let mut hits = collect_hits_in_tree(
        &root.join("crates/harness-agents/src"),
        root,
        None,
        &["crate::hooks::"],
        |path, needle| format!("{path} reaches back into hooks via `{needle}`"),
    );
    hits.extend(collect_hits_in_tree(
        &root.join("src/session"),
        root,
        None,
        &["crate::hooks::"],
        |path, needle| format!("{path} reaches back into hooks via `{needle}`"),
    ));
    hits.extend(collect_hits_in_tree(
        &root.join("crates/harness-session/src"),
        root,
        None,
        &["crate::hooks::"],
        |path, needle| format!("{path} reaches back into hooks via `{needle}`"),
    ));
    hits.extend(collect_hits_in_tree(
        &root.join("src/task_board"),
        root,
        None,
        &["crate::hooks::"],
        |path, needle| format!("{path} reaches back into hooks via `{needle}`"),
    ));
    hits.extend(collect_hits_in_tree(
        &root.join("crates/harness-task-board/src"),
        root,
        None,
        &["crate::hooks::"],
        |path, needle| format!("{path} reaches back into hooks via `{needle}`"),
    ));

    hits.retain(|hit| !known_exceptions.iter().any(|known| hit.starts_with(known)));

    assert!(
        hits.is_empty(),
        "agents::, session::, and task_board:: should depend on hooks only through the \
         allowed hooks -> {{agents, session}} direction, never the reverse:\n{}",
        hits.join("\n")
    );
}
