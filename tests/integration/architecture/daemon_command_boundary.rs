use std::path::Path;

use super::helpers::collect_hits_in_paths;

/// #591/#710: a domain command surface should not decide for itself whether to
/// delegate to a live daemon by reaching into the root crate's typed
/// `daemon::client` facade. These call sites went through the leaf
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
/// own `get_optional`. `session::service::mod`'s own cascade added a
/// `Handle::try_current().is_err()` guard per call, mirroring the one
/// `session::service::runtime_registration::register_agent_runtime_session`
/// already carries, everywhere the daemon's own mutation fallbacks reach
/// these functions directly from an async worker.
///
/// `task_board::transport::daemon_client()` and its
/// `crate::daemon::client::DaemonClient` import stay for now: four nested
/// command modules (`item_commands`, `host`, `orchestrator`,
/// `orchestrator_tokens`) still call typed facade methods backed by PUT or
/// DELETE, which the leaf client did not support until #787 added generic
/// `put`/`delete` there; converting those is the next batch.
/// `session::transport::support`'s `daemon_client()` helper (still needed by
/// the managed-agent command surfaces that did not move this round) is not
/// covered here either.
#[test]
fn daemon_command_surfaces_stay_off_the_root_daemon_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_paths(
        root,
        &[
            "src/agents/service.rs",
            "src/session/service/conversions.rs",
            "src/session/service/lifecycle.rs",
            "src/session/service/runtime_registration.rs",
            "src/session/service/signals.rs",
            "src/session/service/tasks.rs",
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

/// `session::service::queries` and its parent `mod.rs` still reach into
/// `crate::daemon::index` for cross-project session discovery: a
/// filesystem-scanning module the daemon's own mutation fallbacks also use
/// directly to resolve a project dir, with no HTTP-reachable equivalent for
/// the leaf client to wrap. Everything else in these two files - the typed
/// `daemon::client` facade calls - moved to `harness_daemon_client`, so this
/// guard is scoped to that narrower needle instead of the blanket
/// `crate::daemon::` used above.
#[test]
fn session_queries_and_service_mod_stay_off_the_daemon_client_facade() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let hits = collect_hits_in_paths(
        root,
        &[
            "src/session/service/mod.rs",
            "src/session/service/queries.rs",
        ],
        &["crate::daemon::client"],
        |path, needle| format!("{path} reaches back into the daemon via `{needle}`"),
    );

    assert!(
        hits.is_empty(),
        "these files should stay off `crate::daemon::client`, using `harness_daemon_client` instead:\n{}",
        hits.join("\n")
    );
}
