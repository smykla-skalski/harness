use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use harness::daemon::agent_tui::{
    AgentTuiInput, AgentTuiInputRequest, AgentTuiInputSequence, AgentTuiInputSequenceStep,
    AgentTuiLaunchProfile, AgentTuiManagerHandle, AgentTuiSize, AgentTuiSnapshot,
    AgentTuiStartRequest, AgentTuiStatus,
};
use harness::daemon::bridge::{AgentTuiStartSpec, BridgeClient, BridgeStatusReport};
use harness::daemon::db::DaemonDb;
use harness::daemon::protocol::{SessionStartRequest, StreamEvent};
use harness::daemon::service as daemon_service;
use harness::session::types::SessionRole;
use tempfile::tempdir;
use tokio::sync::broadcast;

use self::support::{
    ensure_host_home, harness_binary, output_text, run_bridge, run_bridge_with_data_home,
    wait_for_bridge_exit, wait_for_bridge_state,
};
use super::helpers::ManagedChild;

const BRIDGE_WAIT_TIMEOUT: Duration = Duration::from_secs(10);
const BRIDGE_POLL_INTERVAL: Duration = Duration::from_millis(100);

mod lifecycle;
mod readiness;
mod recovery;
mod runtime;
mod support;
