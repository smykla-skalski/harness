use std::path::PathBuf;
use std::sync::Mutex;

#[cfg(test)]
use std::sync::Arc;

mod audit;
mod config;
mod config_migration;
mod identity;
mod locks;
mod manifest;
mod migration;
mod ownership;
mod paths;

#[cfg(test)]
mod tests;
// `pub`, not `pub(crate)`: the daemon-routing fixtures this crate's own unit
// tests use are also the only way `tests/integration_daemon.rs`'s
// `session_service_daemon_*` scenarios can fake a running daemon, since that
// binary links `harness` as an ordinary dependency where `cfg(test)` is
// never set. Gating on `daemon-runtime` rather than always-on keeps it out of
// the default-feature build the same way the rest of this module's
// daemon-only surface is gated. Lives here, not under the now-deleted
// `daemon::client` facade it used to sit beside, because every type and
// constant it fabricates (`DaemonManifest`, `DaemonOwnership`,
// `ScopedDaemonRootOverride`, `DAEMON_LOCK_FILE`, `auth_token_path`,
// `write_manifest`) is this module's own.
#[cfg(any(test, feature = "daemon-runtime"))]
pub mod test_support;

pub use crate::infra::persistence::flock::FlockGuard;
pub use harness_protocol::daemon::{
    DaemonAuditEvent, DaemonBinaryStamp, DaemonDiagnostics, DaemonManifest,
    HostBridgeCapabilityManifest, HostBridgeManifest,
};

pub use audit::{
    append_event, append_event_best_effort, append_event_entry, diagnostics, ensure_auth_token,
    read_recent_events,
};
pub use config::{
    DaemonRuntimeConfig, VALID_LOG_LEVELS, load_persisted_log_level, load_runtime_config,
    parse_log_level, persist_log_level, replace_task_board_git_runtime_secrets,
    replace_task_board_github_tokens, replace_task_board_openrouter_token,
    task_board_github_repository_token, task_board_github_token, task_board_openrouter_token,
};
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use config::{
    load_runtime_config_raw, overlay_task_board_git_runtime_profile_secrets,
    overlay_task_board_git_runtime_secret_flags, overlay_task_board_git_runtime_secrets,
    retaining_task_board_git_runtime_secrets,
};
#[cfg(test)]
pub use config::{
    load_task_board_git_runtime_config, persist_task_board_git_runtime_config,
    task_board_git_runtime_profile,
};
#[cfg(any(test, feature = "daemon-runtime"))]
pub(crate) use config_migration::{
    remove_migrated_task_board_config_after_ack, remove_migrated_task_board_config_if_safe,
    task_board_git_runtime_secret_handoff_digest,
};
pub use identity::{
    DAEMON_HOST_FINGERPRINT_ENV, DAEMON_NAME_ENV, DaemonIdentity, ensure_daemon_identity,
    reported_daemon_identity, set_daemon_name,
};
pub use locks::{acquire_singleton_lock, daemon_lock_is_held, daemon_lock_is_held_at};
pub use manifest::{clear_manifest_for_pid, load_manifest, load_running_manifest, write_manifest};
pub use migration::{
    LegacyDaemonRootMigration, MigrationDecision, migrate_legacy_daemon_root_at,
    migrate_legacy_daemon_root_for_current_process,
};
pub use ownership::{
    DaemonOwnership, ScopedOwnershipOverride, daemon_ownership_from_env_or_default,
};
pub use paths::{
    ScopedDaemonRootOverride, auth_token_path, base_daemon_dir, config_path, daemon_root,
    daemon_root_for_ownership, default_daemon_root, ensure_daemon_dirs, events_path, identity_path,
    launch_agent_path, legacy_launch_agent_path, lock_path, log_path, manifest_path,
    set_daemon_root_override,
};

#[cfg(any(test, feature = "bridge-runtime", feature = "daemon-runtime"))]
pub(crate) use locks::{acquire_flock_exclusive, flock_is_held_at};

const LAUNCH_AGENTS_DIR: &str = "LaunchAgents";
const CURRENT_LAUNCH_AGENT_PLIST: &str = "io.harness.daemon.plist";
const LEGACY_LAUNCH_AGENT_PLIST: &str = "io.harness.monitor.daemon.plist";
pub(crate) const DAEMON_LOCK_FILE: &str = "daemon.lock";
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub(crate) const BRIDGE_LOCK_FILE: &str = "bridge.lock";
const MANIFEST_LOCK_FILE: &str = "manifest.lock";
pub(crate) const APP_GROUP_ID_ENV: &str = "HARNESS_APP_GROUP_ID";
pub(crate) const DAEMON_DATA_HOME_ENV: &str = "HARNESS_DAEMON_DATA_HOME";
pub(crate) const DAEMON_OWNERSHIP_ENV: &str = "HARNESS_DAEMON_OWNERSHIP";

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
