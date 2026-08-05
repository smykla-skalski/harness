use std::path::Path;

use super::helpers::collect_hits_in_tree;

/// #1066: `service` must stay buildable as its own compilation unit, with no
/// dependency on `http` or `websocket`. `http` and `websocket` already depend
/// on `service` one-way (43 files, confirmed by direct inspection when this
/// guard was added), so a `service` file reaching back into either would be a
/// real cycle, not just a style issue. `crate::daemon::serve` and the
/// task-board read-only coordinator sit outside the literal `service/`
/// directory and still carry a real dependency on `http`'s `DaemonHttpState`
/// and a few of its own logic functions (`run_codex_agent_blocking`,
/// `task_board_route_executor`, `run_broadcast_fanout`); that remaining
/// coupling is tracked by #1425 and #1426; this guard only covers the
/// literal `service/` directory, which is already clean.
#[test]
fn service_does_not_depend_on_http_or_websocket() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"));
    let service_dir = root.join("crates/harness-daemon/src/daemon/service");

    let hits = collect_hits_in_tree(
        &service_dir,
        root,
        None,
        &["crate::daemon::http::", "crate::daemon::websocket::"],
        |path, needle| format!("{path} reaches into `{needle}`, which service must not depend on"),
    );

    assert!(
        hits.is_empty(),
        "`service` must stay free of `http`/`websocket` dependencies (#1066):\n{}",
        hits.join("\n")
    );
}
