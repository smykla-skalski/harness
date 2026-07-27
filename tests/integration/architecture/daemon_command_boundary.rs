use std::path::Path;

use super::helpers::collect_hits_in_paths;

/// #591/#710: a domain command surface should not decide for itself whether to
/// delegate to a live daemon by reaching into the root crate's typed
/// `daemon::client` facade. These fourteen call sites went through the leaf
/// `harness-daemon-client` instead, the same crate `harness-hook` already uses
/// for the same daemon calls, following the inversion #716 used for the ACP
/// probe cache. `terminal.rs` also used to import its `AgentTuiInput`,
/// `AgentTuiKey`, and `AgentTuiInputRequest` argument types from
/// `crate::daemon::agent_tui`; those types are pure wire shapes with no
/// daemon-runtime dependency, so they moved to `harness_protocol` next to
/// their sibling `AgentTuiResizeRequest`, closing that back-edge too. The
/// eight `task_board::transport` files converted here needed no type move:
/// their request/response wire types already lived in the domain-owned
/// `task_board::wire`, with `daemon::protocol` only re-exporting them, so
/// converting was purely a client-construction swap plus a
/// `leaf_daemon_client()` sibling to `task_board::transport::daemon_client()`
/// that replicates its database-capability check through the leaf client's
/// own `get_optional`. `task_board::transport::daemon_client()` and its
/// `crate::daemon::client::DaemonClient` import stay for now: four nested
/// command modules (`item_commands`, `host`, `orchestrator`,
/// `orchestrator_tokens`) still call typed facade methods backed by PUT or
/// DELETE, which the leaf client did not support until #787 added generic
/// `put`/`delete` there; converting those is the next batch. Two more
/// `crate::daemon` back-edges remain in this tree and are intentionally not
/// covered here: `session::service::mod`'s `DaemonClient`/`daemon::index`
/// imports (cascading into `lifecycle`/`tasks`/`queries`/`signals`, several of
/// whose functions the daemon's own HTTP and websocket handlers call
/// reentrantly while holding a live `db_guard` - converting them needs the
/// same per-call reentrancy guard #776 added for
/// `runtime_registration::register_agent_runtime_session`, not just an import
/// swap), and `session::transport::support`'s `daemon_client()` helper (still
/// needed by the managed-agent command surfaces that did not move this
/// round). Closing those needs either a larger domain-owned redesign or
/// converting each remaining typed method one by one, neither of which this
/// guard should pretend is already done.
#[test]
fn daemon_command_surfaces_stay_off_the_root_daemon_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_paths(
        root,
        &[
            "src/agents/service.rs",
            "src/session/service/runtime_registration.rs",
            "src/session/transport/task.rs",
            "src/session/transport/improver.rs",
            "src/session/transport/session_commands.rs",
            "src/session/transport/managed_agents/terminal.rs",
            "src/task_board/transport/catalog.rs",
            "src/task_board/transport/dispatch.rs",
            "src/task_board/transport/evaluate.rs",
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
