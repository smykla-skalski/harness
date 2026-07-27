use std::path::Path;

use super::helpers::collect_hits_in_paths;

/// #591/#710: a domain command surface should not decide for itself whether to
/// delegate to a live daemon by reaching into the root crate's typed
/// `daemon::client` facade. These five call sites went through the leaf
/// `harness-daemon-client` instead, the same crate `harness-hook` already uses
/// for the same daemon calls, following the inversion #716 used for the ACP
/// probe cache. Five more `crate::daemon` back-edges remain in this tree and
/// are intentionally not covered here; closing them needs either a larger
/// domain-owned type move or de-duplicating the leaf client's readiness and
/// discovery logic against the root facade's, neither of which this guard
/// should pretend is already done.
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
