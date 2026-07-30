//! The daemon's on-disk root: where it lives, whether another instance is
//! already running there, its persisted manifest, which ownership subtree
//! (managed vs. external) it resolves to, and its append-only audit log.
//!
//! This is the primitive layer `harness-bridge` needs too, so it stays a
//! separate crate from [`harness-daemon-state`]'s identity, legacy-migration,
//! and task-board-config surface: those pull in task-board's own runtime
//! config types, which the bridge binary has no reason to depend on.

use std::path::PathBuf;
use std::sync::Mutex;

#[cfg(test)]
use std::sync::Arc;

mod audit;
mod locks;
mod manifest;
mod ownership;
mod paths;

#[cfg(test)]
mod tests;

// `pub`, not `pub(crate)`: the daemon-routing fixtures this crate's own unit
// tests use are also the only way `tests/integration_daemon.rs`'s
// `session_service_daemon_*` scenarios (in the root `harness` crate) can fake
// a running daemon, since that binary links `harness` as an ordinary
// dependency where `cfg(test)` is never set. Gating on `daemon-runtime`
// rather than always-on keeps it out of the default-feature build; `harness-daemon`'s
// own `direct_session_start` unit test reaches this module the same way but
// through `test-support` instead, since it needs `read_http_request` and
// `write_http_response` without pulling in the rest of the daemon-runtime build.
#[cfg(any(test, feature = "daemon-runtime", feature = "test-support"))]
pub mod test_support;

pub use harness_infra::persistence::flock::FlockGuard;
pub use harness_protocol::daemon::{
    DaemonAuditEvent, DaemonBinaryStamp, DaemonDiagnostics, DaemonManifest,
    HostBridgeCapabilityManifest, HostBridgeManifest,
};

pub use audit::{
    append_event, append_event_best_effort, append_event_entry, diagnostics, ensure_auth_token,
    read_recent_events,
};
pub use locks::{
    acquire_flock_exclusive, acquire_singleton_lock, daemon_lock_is_held, daemon_lock_is_held_at,
    flock_is_held_at,
};
pub use manifest::{clear_manifest_for_pid, load_manifest, load_running_manifest, write_manifest};
pub use ownership::{
    DaemonOwnership, ScopedOwnershipOverride, daemon_ownership_from_env_or_default,
};
pub use paths::{
    ScopedDaemonRootOverride, auth_token_path, base_daemon_dir, config_path, daemon_root,
    daemon_root_for_ownership, default_daemon_root, ensure_daemon_dirs, events_path, identity_path,
    launch_agent_path, legacy_launch_agent_path, lock_path, log_path, manifest_path,
    set_daemon_root_override,
};

const LAUNCH_AGENTS_DIR: &str = "LaunchAgents";
const CURRENT_LAUNCH_AGENT_PLIST: &str = "io.harness.daemon.plist";
const LEGACY_LAUNCH_AGENT_PLIST: &str = "io.harness.monitor.daemon.plist";
pub const DAEMON_LOCK_FILE: &str = "daemon.lock";
pub const BRIDGE_LOCK_FILE: &str = "bridge.lock";
pub const MANIFEST_LOCK_FILE: &str = "manifest.lock";
pub const APP_GROUP_ID_ENV: &str = "HARNESS_APP_GROUP_ID";
pub const DAEMON_DATA_HOME_ENV: &str = "HARNESS_DAEMON_DATA_HOME";
pub const DAEMON_OWNERSHIP_ENV: &str = "HARNESS_DAEMON_OWNERSHIP";

static DAEMON_ROOT_OVERRIDE: Mutex<Option<PathBuf>> = Mutex::new(None);

#[cfg(test)]
type ManifestWriteHook = dyn Fn() + Send + Sync + 'static;

#[cfg(test)]
static MANIFEST_WRITE_HOOK: Mutex<Option<Arc<ManifestWriteHook>>> = Mutex::new(None);

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
