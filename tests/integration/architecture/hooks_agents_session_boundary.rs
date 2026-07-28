use std::path::Path;

use super::helpers::collect_hits_in_tree;

/// `hooks` may depend on `session` and `agents` - `hooks::runtime` genuinely
/// needs `agents::runtime` for pending-signal pickup and
/// `agents::service`/`session::service` to record what happened and resolve a
/// runtime session - but nothing under `src/agents` or `src/session` may
/// reach back into `crate::hooks`; a real edge in that direction would block
/// ever giving either domain its own crate. Every current hit in this scan is
/// a type-only import of `HookAgent`, `NormalizedEvent`/`NormalizedHookContext`,
/// or `NormalizedHookResult` through the `crate::hooks::adapters`/
/// `crate::hooks::protocol` re-export shims; the canonical definitions live in
/// `harness_protocol`/`harness_kernel`, so every call site imports from there
/// directly instead.
///
/// `src/agents/kind/mod.rs` and `src/session/types/agent_tests.rs` are the two
/// expected survivors. Root's own `agents::kind` and `session::types` are
/// inline re-export modules (`pub mod kind { pub use harness_protocol::agent::...; }`,
/// `pub mod types { pub use harness_protocol::session::*; }` in
/// `src/agents/mod.rs`/`src/session/mod.rs`) rather than `mod kind;`/`mod types;`
/// pointing at these files, so neither file is even part of root's own build:
/// `harness-protocol` pulls each one in verbatim with `#[path]` (`kind/mod.rs`
/// to back `AcpAgentId`/`DisconnectReason`/`RuntimeKind`, `session/types/mod.rs`
/// - and everything it `mod`-declares, `agent_tests` included - to back the
/// `session` module) to give those types a single physical definition,
/// mirroring how `harness-daemon`, `harness-bridge`, and `harness-hook` already
/// share other root files the same way. Their `HookAgent` references have to
/// stay on the `crate::hooks::adapters::HookAgent` shim every one of those
/// `#[path]` hosts already provides, because a crate cannot name itself in a
/// `use` path - `harness_protocol::agent::HookAgent`, the direct import every
/// other call site in this scan now uses, does not resolve when either file is
/// compiled as part of `harness-protocol` itself (confirmed with a throwaway
/// edit against `cargo check -p harness-protocol`). Those references never
/// leave `harness-protocol`'s own compilation, so they are not real
/// cross-crate edges.
#[test]
fn agents_and_session_stay_off_the_hooks_module() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let known_exceptions = [
        "src/agents/kind/mod.rs",
        "src/session/types/agent_tests.rs",
    ];

    let mut hits = collect_hits_in_tree(
        &root.join("src/agents"),
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
        &root.join("src/task_board"),
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
