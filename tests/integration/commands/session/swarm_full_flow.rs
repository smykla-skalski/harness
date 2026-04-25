//! Ignored end-to-end entrypoint for the 16-act real-runtime swarm workflow.
//!
//! This intentionally shells out to the repo-native mise lane because the
//! scenario spans the Rust CLI, external daemon, and the macOS Monitor
//! XCUITest host. Fast integration tests cover the individual state-machine
//! pieces; this wrapper is for explicit slow/e2e runs only.

use std::process::Command;

#[test]
#[ignore = "requires real claude/codex auth, a macOS UI host, and Xcode"]
fn swarm_full_flow_mise_lane_passes() {
    let repo_root = std::env::current_dir().expect("current dir");
    let status = Command::new("mise")
        .arg("run")
        .arg("e2e:swarm-full-flow")
        .current_dir(&repo_root)
        .status()
        .expect("run mise swarm e2e lane");

    assert!(
        status.success(),
        "mise run e2e:swarm-full-flow failed with status {status}"
    );
}
