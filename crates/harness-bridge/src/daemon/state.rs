use std::path::PathBuf;
use std::sync::Mutex;

#[path = "../../../../crates/harness-daemon/src/daemon/state/audit.rs"]
mod audit;
#[path = "../../../../crates/harness-daemon/src/daemon/state/locks.rs"]
mod locks;
#[path = "../../../../crates/harness-daemon/src/daemon/state/manifest.rs"]
mod manifest;
#[path = "../../../../crates/harness-daemon/src/daemon/state/ownership.rs"]
mod ownership;
#[path = "../../../../crates/harness-daemon/src/daemon/state/paths.rs"]
mod paths;

pub use crate::infra::persistence::flock::FlockGuard;
pub use harness_protocol::daemon::{
    DaemonAuditEvent, DaemonBinaryStamp, DaemonDiagnostics, DaemonManifest,
    HostBridgeCapabilityManifest, HostBridgeManifest,
};

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

pub type DaemonLockGuard = FlockGuard;

fn run_manifest_write_hook() {}
