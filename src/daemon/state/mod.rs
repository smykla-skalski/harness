use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

#[cfg(test)]
use std::sync::Arc;

use serde::{Deserialize, Serialize};

mod audit;
mod locks;
mod manifest;
mod paths;

#[cfg(test)]
mod tests;

pub use crate::infra::persistence::flock::FlockGuard;
pub use audit::{
    append_event, append_event_best_effort, diagnostics, ensure_auth_token, read_recent_events,
};
pub use locks::{acquire_singleton_lock, daemon_lock_is_held, daemon_lock_is_held_at};
pub use manifest::{clear_manifest_for_pid, load_manifest, load_running_manifest, write_manifest};
pub use paths::{
    auth_token_path, daemon_root, default_daemon_root, ensure_daemon_dirs, events_path,
    launch_agent_path, legacy_launch_agent_path, lock_path, manifest_path,
    set_daemon_root_override,
};

pub(crate) use locks::{acquire_flock_exclusive, flock_is_held_at};

const LAUNCH_AGENTS_DIR: &str = "LaunchAgents";
const CURRENT_LAUNCH_AGENT_PLIST: &str = "io.harness.daemon.plist";
const LEGACY_LAUNCH_AGENT_PLIST: &str = "io.harness.monitor.daemon.plist";
pub(crate) const DAEMON_LOCK_FILE: &str = "daemon.lock";
pub(crate) const BRIDGE_LOCK_FILE: &str = "bridge.lock";
const MANIFEST_LOCK_FILE: &str = "manifest.lock";
pub(crate) const APP_GROUP_ID_ENV: &str = "HARNESS_APP_GROUP_ID";
pub(crate) const DAEMON_DATA_HOME_ENV: &str = "HARNESS_DAEMON_DATA_HOME";

static DAEMON_ROOT_OVERRIDE: Mutex<Option<PathBuf>> = Mutex::new(None);

#[cfg(test)]
type ManifestWriteHook = dyn Fn() + Send + Sync + 'static;

#[cfg(test)]
static MANIFEST_WRITE_HOOK: Mutex<Option<Arc<ManifestWriteHook>>> = Mutex::new(None);

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

fn default_host_bridge_enabled() -> bool {
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

#[cfg(test)]
fn set_manifest_write_hook(hook: Option<Arc<ManifestWriteHook>>) {
    *MANIFEST_WRITE_HOOK
        .lock()
        .expect("manifest write hook mutex poisoned") = hook;
}

fn run_manifest_write_hook() {
    #[cfg(test)]
    if let Some(hook) = MANIFEST_WRITE_HOOK
        .lock()
        .expect("manifest write hook mutex poisoned")
        .clone()
    {
        hook();
    }
}
