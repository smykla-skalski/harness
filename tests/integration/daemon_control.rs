use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::agent_tui::{AgentTuiSnapshot, AgentTuiStatus};
use harness::daemon::bridge::BridgeStatusReport;
use harness::daemon::protocol::{CodexRunSnapshot, CodexRunStatus, SessionMutationResponse};
use harness::daemon::service::DaemonStatusReport;
use harness::daemon::transport::HARNESS_MONITOR_APP_GROUP_ID;
use harness::session::types::SessionState;
use serde_json::{Value, json};
use tempfile::tempdir;
use tokio::runtime::Runtime;

use super::helpers::ManagedChild;

mod bridge;
mod daemon_api;
mod lifecycle;
mod process;
mod tui;

use daemon_api::*;
use process::*;

const DAEMON_WAIT_TIMEOUT: Duration = Duration::from_secs(15);
const DAEMON_WAIT_INTERVAL: Duration = Duration::from_millis(250);
const DAEMON_HTTP_TIMEOUT: Duration = Duration::from_secs(1);
const COMMAND_WAIT_TIMEOUT: Duration = Duration::from_secs(10);

#[test]
fn daemon_stop_succeeds_when_offline() {
    let tmp = tempdir().expect("tempdir");
    let home = tmp.path().join("home");
    let xdg = tmp.path().join("xdg");
    std::fs::create_dir_all(&home).expect("create home");
    std::fs::create_dir_all(&xdg).expect("create xdg");

    let output = run_harness(&home, &xdg, &["daemon", "stop"]);
    assert!(
        output.status.success(),
        "stop failed: {}",
        output_text(&output)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout), "stopped\n");
}
