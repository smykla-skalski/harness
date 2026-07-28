use std::path::Path;

use super::helpers::collect_hits_in_paths;

/// A domain command surface should not decide for itself whether to
/// delegate to a live daemon by reaching into the root crate's typed
/// `daemon::client` facade. These call sites went through the leaf
/// `harness-daemon-client` instead, the same crate `harness-hook` already uses
/// for the same daemon calls, following the same client-inversion pattern
/// already used for the ACP probe cache. `terminal.rs` also used to import
/// its `AgentTuiInput`, `AgentTuiKey`, and `AgentTuiInputRequest` argument
/// types from `crate::daemon::agent_tui`; those types are pure wire shapes
/// with no daemon-runtime dependency, so they moved to `harness_protocol`
/// next to their sibling `AgentTuiResizeRequest`, closing that back-edge too.
/// Every `task_board::transport` file's request/response wire types already
/// lived in the domain-owned `task_board::wire`, with `daemon::protocol` only
/// re-exporting them, so converting was purely a client-construction swap.
/// The last four files (`item_commands`, `host`, `orchestrator`,
/// `orchestrator_tokens`) called typed facade methods backed by PUT or
/// DELETE, which needed the leaf client to gain generic `put`/`delete`
/// support first; `item_commands.rs` additionally needed its own port of the
/// facade's list-page-walk (dedup, cursor-repeat, and page-count faults) and
/// query-string rendering, since that behavior lived only in the facade and
/// nowhere in `task_board::wire`. `task_board::transport::daemon_client()`
/// and its `crate::daemon::client::DaemonClient` import are gone now that no
/// caller needs them, closing this back-edge entirely; `leaf_daemon_client()`
/// keeps its name rather than reclaiming `daemon_client()`, since renaming it
/// back would touch every file in this list for a cosmetic reason alone.
/// `session::service::mod`'s own cascade added a
/// `Handle::try_current().is_err()` guard per call, mirroring the one
/// `session::service::runtime_registration::register_agent_runtime_session`
/// already carries, everywhere the daemon's own mutation fallbacks reach
/// these functions directly from an async worker.
///
/// With every `task_board::transport` caller moved off it, the facade's own
/// `daemon::client::task_board`/`task_board_orchestrator`/`task_board_list`
/// modules (and their dedicated test files) had zero callers left anywhere in
/// the tree - confirmed by checking every other construction site of
/// `daemon::client::DaemonClient`, not just this one - so they were deleted
/// outright rather than left as an unused duplicate of the ported logic
/// above. That in turn left the facade's own `put` (in `daemon::client::http`)
/// with no caller either, since only the deleted task-board methods ever used
/// it; `get`/`get_optional`/`post`/`delete` there still back the managed-agent
/// and session methods in `daemon::client::api` and stay.
///
/// `session::service::queries` and its parent `mod.rs` used to keep a second,
/// narrower back-edge into `crate::daemon::index` for cross-project session
/// discovery even after the rest of this cascade landed: a filesystem-scanning
/// module with no daemon-only state (no DB handle, no HTTP wire types) that
/// the daemon's own mutation fallbacks also called directly to resolve a
/// project dir. That module moved to `session::index`, so both sides call the
/// same code without either depending on the other; `daemon::mod` re-exports
/// it as `index` so the daemon's own call sites across `daemon::db`,
/// `daemon::service`, `daemon::watch`, `daemon::snapshot`, and
/// `daemon::timeline` did not need touching. Both files now join the blanket
/// check below instead of needing a narrower one of their own.
///
/// `session::transport::support`'s `daemon_client()` helper backed the
/// remaining managed-agent command surfaces (terminal start/attach, Codex
/// steer/interrupt/approval, ACP session list/close/delete, ACP lifecycle
/// start/inspect/logout, and session adoption) through the same typed root
/// facade. It now returns the leaf `harness_daemon_client::DaemonClient`
/// instead, so every one of those call sites builds its own request against
/// the generic `get`/`post`/`delete`, verified against the daemon's actual
/// route registration. `terminal.rs` no longer needs its own private
/// duplicate of the helper now that `support::daemon_client()` returns the
/// same leaf type, so it was folded back onto the shared one. Because this
/// is a text-grep guard and the back-edge lived entirely inside
/// `support.rs` (its callers never wrote `crate::daemon::` themselves), the
/// managed-agent surfaces were already grep-clean before the fix; the actual
/// proof that they now hit the leaf client lives in the fake-daemon-backed
/// daemon-routing suite, now `tests/integration/session_transport_managed_agents_daemon_routing`
/// since `session::service` and `session::transport` both moved into the
/// `harness-session` crate after this cascade landed.
#[test]
fn daemon_command_surfaces_stay_off_the_root_daemon_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_paths(
        root,
        &[
            "crates/harness-agents/src/service.rs",
            "crates/harness-session/src/service/mod.rs",
            "crates/harness-session/src/service/conversions.rs",
            "crates/harness-session/src/service/lifecycle.rs",
            "crates/harness-session/src/service/queries.rs",
            "crates/harness-session/src/service/runtime_registration.rs",
            "crates/harness-session/src/service/signals.rs",
            "crates/harness-session/src/service/tasks.rs",
            "crates/harness-session/src/transport/task.rs",
            "crates/harness-session/src/transport/improver.rs",
            "crates/harness-session/src/transport/recover.rs",
            "crates/harness-session/src/transport/session_commands.rs",
            "crates/harness-session/src/transport/support.rs",
            "crates/harness-session/src/transport/managed_agents.rs",
            "crates/harness-session/src/transport/managed_agents/acp_sessions.rs",
            "crates/harness-session/src/transport/managed_agents/attach.rs",
            "crates/harness-session/src/transport/managed_agents/codex.rs",
            "crates/harness-session/src/transport/managed_agents/start.rs",
            "crates/harness-session/src/transport/managed_agents/terminal.rs",
            "src/task_board/transport.rs",
            "src/task_board/transport/catalog.rs",
            "src/task_board/transport/dispatch.rs",
            "src/task_board/transport/evaluate.rs",
            "src/task_board/transport/host.rs",
            "src/task_board/transport/item_commands.rs",
            "src/task_board/transport/orchestrator.rs",
            "src/task_board/transport/orchestrator_tokens.rs",
            "src/task_board/transport/planning.rs",
            "src/task_board/transport/policy.rs",
            "src/task_board/transport/policy_io.rs",
            "src/task_board/transport/sync.rs",
            "src/task_board/transport/triage_escalation.rs",
        ],
        &["crate::daemon::"],
        |path, needle| format!("{path} reaches back into the daemon via `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "these command surfaces should stay off `crate::daemon`, using `harness_daemon_client` instead:\n{}",
        hits.join("\n")
    );
}
