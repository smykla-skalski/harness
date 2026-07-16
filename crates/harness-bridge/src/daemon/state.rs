use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

#[path = "../../../../src/daemon/state/audit.rs"]
mod audit;
#[path = "../../../../src/daemon/state/locks.rs"]
mod locks;
#[path = "../../../../src/daemon/state/manifest.rs"]
mod manifest;
#[path = "../../../../src/daemon/state/ownership.rs"]
mod ownership;
#[path = "../../../../src/daemon/state/paths.rs"]
mod paths;

pub use crate::infra::persistence::flock::FlockGuard;
pub use audit::*;
pub use locks::*;
pub use manifest::*;
pub use ownership::*;
pub use paths::*;

const LAUNCH_AGENTS_DIR: &str = "LaunchAgents";
const CURRENT_LAUNCH_AGENT_PLIST: &str = "io.harness.daemon.plist";
const LEGACY_LAUNCH_AGENT_PLIST: &str = "io.harness.monitor.daemon.plist";
pub(crate) const DAEMON_LOCK_FILE: &str = "daemon.lock";
pub(crate) const BRIDGE_LOCK_FILE: &str = "bridge.lock";
const MANIFEST_LOCK_FILE: &str = "manifest.lock";
pub(crate) const APP_GROUP_ID_ENV: &str = "HARNESS_APP_GROUP_ID";
pub(crate) const DAEMON_DATA_HOME_ENV: &str = "HARNESS_DAEMON_DATA_HOME";
pub(crate) const DAEMON_OWNERSHIP_ENV: &str = "HARNESS_DAEMON_OWNERSHIP";

static DAEMON_ROOT_OVERRIDE: Mutex<Option<PathBuf>> = Mutex::new(None);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct HostBridgeCapabilityManifest {
    #[serde(default = "default_host_bridge_enabled")]
    pub enabled: bool,
    #[serde(default)]
    pub healthy: bool,
    pub transport: String,
    #[serde(default)]
    pub endpoint: Option<String>,
    #[serde(default)]
    pub metadata: BTreeMap<String, String>,
}

const fn default_host_bridge_enabled() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct HostBridgeManifest {
    #[serde(default)]
    pub running: bool,
    #[serde(default)]
    pub socket_path: Option<String>,
    #[serde(default)]
    pub capabilities: BTreeMap<String, HostBridgeCapabilityManifest>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DaemonBinaryStamp {
    pub helper_path: String,
    pub device_identifier: u64,
    pub inode: u64,
    pub file_size: u64,
    pub modification_time_interval_since_1970: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonManifest {
    pub version: String,
    pub pid: u32,
    pub endpoint: String,
    pub started_at: String,
    pub token_path: String,
    #[serde(default)]
    pub sandboxed: bool,
    #[serde(default)]
    pub host_bridge: HostBridgeManifest,
    #[serde(default)]
    pub revision: u64,
    #[serde(default)]
    pub updated_at: String,
    #[serde(default)]
    pub binary_stamp: Option<DaemonBinaryStamp>,
    #[serde(default)]
    pub ownership: DaemonOwnership,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonAuditEvent {
    pub recorded_at: String,
    pub level: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonDiagnostics {
    pub daemon_root: String,
    pub manifest_path: String,
    pub auth_token_path: String,
    pub auth_token_present: bool,
    pub events_path: String,
    pub database_path: String,
    pub database_size_bytes: u64,
    pub last_event: Option<DaemonAuditEvent>,
}

pub type DaemonLockGuard = FlockGuard;

fn run_manifest_write_hook() {}
