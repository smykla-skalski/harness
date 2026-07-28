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
#[test]
fn agents_and_session_stay_off_the_hooks_module() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));

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

    assert!(
        hits.is_empty(),
        "agents::, session::, and task_board:: should depend on hooks only through the \
         allowed hooks -> {{agents, session}} direction, never the reverse:\n{}",
        hits.join("\n")
    );
}
