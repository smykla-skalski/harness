use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io::{self, Write as _};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use fs2::FileExt;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty, write_text};
use crate::workspace::{dirs_home, harness_data_root, host_home_dir, utc_now};

const LAUNCH_AGENTS_DIR: &str = "LaunchAgents";
const CURRENT_LAUNCH_AGENT_PLIST: &str = "io.harness.daemon.plist";
const LEGACY_LAUNCH_AGENT_PLIST: &str = "io.harness.monitor.daemon.plist";
pub(crate) const DAEMON_LOCK_FILE: &str = "daemon.lock";
pub(crate) const APP_GROUP_ID_ENV: &str = "HARNESS_APP_GROUP_ID";
pub(crate) const DAEMON_DATA_HOME_ENV: &str = "HARNESS_DAEMON_DATA_HOME";

/// Process-local override for [`daemon_root`]. Installed by
/// [`set_daemon_root_override`] (typically from
/// `crate::daemon::discovery::adopt_running_daemon_root`) and by tests that
/// want to pin the root without racy env mutation.
///
/// The `Mutex` is `const`-constructible and the whole module is single-writer
/// in practice (every writer goes through [`set_daemon_root_override`]), so
/// the lock is contention-free at runtime. Using a mutex instead of
/// [`std::env::set_var`] keeps us sound under the Rust 2024 multithreaded
/// environment rules.
static DAEMON_ROOT_OVERRIDE: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Install a process-local override so every subsequent [`daemon_root`] call
/// returns `path`. Passing `None` clears the override.
///
/// Intended for [`crate::daemon::discovery::adopt_running_daemon_root`] and
/// for tests that need deterministic paths without mutating process env.
///
/// # Panics
/// Panics only if the internal [`std::sync::Mutex`] is poisoned, which would
/// indicate another thread panicked while holding the override lock. The
/// module never holds the lock across any code that can panic, so this is a
/// bug-only failure mode.
pub fn set_daemon_root_override(path: Option<PathBuf>) {
    *DAEMON_ROOT_OVERRIDE
        .lock()
        .expect("daemon root override mutex poisoned") = path;
}

#[must_use]
fn daemon_root_override() -> Option<PathBuf> {
    DAEMON_ROOT_OVERRIDE
        .lock()
        .expect("daemon root override mutex poisoned")
        .clone()
}

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
    /// Whether the daemon is running inside the macOS App Sandbox.
    ///
    /// Legacy manifests written before this field existed default to
    /// `false` so they can be deserialized without migration.
    #[serde(default)]
    pub sandboxed: bool,
    #[serde(default)]
    pub host_bridge: HostBridgeManifest,
    /// Monotonic counter bumped by every [`write_manifest`] call. External
    /// watchers (e.g. the Swift Monitor app) use this to detect in-place
    /// updates such as `host_bridge` changes without requiring a full
    /// reconnect. Legacy manifests decode as `0`.
    #[serde(default)]
    pub revision: u64,
    /// UTC timestamp of the most recent [`write_manifest`] call. Empty on
    /// legacy manifests written before this field existed.
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

#[derive(Debug)]
pub struct DaemonLockGuard {
    file: fs::File,
}

impl Drop for DaemonLockGuard {
    fn drop(&mut self) {
        let _ = self.file.unlock();
    }
}

#[must_use]
pub fn daemon_root() -> PathBuf {
    if let Some(override_root) = daemon_root_override() {
        return override_root;
    }
    default_daemon_root()
}

/// Resolve what [`daemon_root`] would return ignoring any active override.
///
/// Used by discovery/adoption code paths that need to know the process's
/// "natural" default daemon root before installing an override, and by the
/// override itself when no override is active.
#[must_use]
pub fn default_daemon_root() -> PathBuf {
    if let Some(value) = context_scope_value(DAEMON_DATA_HOME_ENV) {
        return PathBuf::from(value).join("harness").join("daemon");
    }
    if let Some(value) = context_scope_value(APP_GROUP_ID_ENV) {
        return host_home_dir()
            .join("Library")
            .join("Group Containers")
            .join(value)
            .join("harness")
            .join("daemon");
    }
    harness_data_root().join("daemon")
}

fn context_scope_value(name: &str) -> Option<String> {
    let value = env::var(name).unwrap_or_default();
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.starts_with("${") && trimmed.ends_with('}') {
        return None;
    }
    if trimmed.eq_ignore_ascii_case("unset") {
        return None;
    }
    Some(trimmed.to_string())
}

#[must_use]
pub fn manifest_path() -> PathBuf {
    daemon_root().join("manifest.json")
}

#[must_use]
pub fn auth_token_path() -> PathBuf {
    daemon_root().join("auth-token")
}

#[must_use]
pub fn events_path() -> PathBuf {
    daemon_root().join("events.jsonl")
}

#[must_use]
pub fn launch_agent_path() -> PathBuf {
    launch_agents_dir().join(CURRENT_LAUNCH_AGENT_PLIST)
}

#[must_use]
pub fn legacy_launch_agent_path() -> PathBuf {
    launch_agents_dir().join(LEGACY_LAUNCH_AGENT_PLIST)
}

#[must_use]
pub fn lock_path() -> PathBuf {
    daemon_root().join(DAEMON_LOCK_FILE)
}

fn launch_agents_dir() -> PathBuf {
    dirs_home().join("Library").join(LAUNCH_AGENTS_DIR)
}

/// Ensure the daemon directory structure exists.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn ensure_daemon_dirs() -> Result<(), CliError> {
    fs_err::create_dir_all(daemon_root())
        .map_err(|error| CliErrorKind::workflow_io(format!("create daemon root: {error}")))?;
    Ok(())
}

/// Acquire the daemon singleton lock for the current process lifetime.
///
/// # Errors
/// Returns `CliError` when another daemon already owns the lock or the lock
/// file cannot be opened.
pub fn acquire_singleton_lock() -> Result<DaemonLockGuard, CliError> {
    ensure_daemon_dirs()?;
    let path = lock_path();
    let file = fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .truncate(false)
        .open(&path)
        .map_err(|error| CliErrorKind::workflow_io(format!("open daemon lock: {error}")))?;
    match file.try_lock_exclusive() {
        Ok(()) => Ok(DaemonLockGuard { file }),
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
            let detail = load_manifest()?.map_or_else(
                || "daemon already running".to_string(),
                |manifest| {
                    format!(
                        "daemon already running (pid {}, endpoint {})",
                        manifest.pid, manifest.endpoint
                    )
                },
            );
            Err(CliErrorKind::workflow_io(detail).into())
        }
        Err(error) => {
            Err(CliErrorKind::workflow_io(format!("lock daemon singleton: {error}")).into())
        }
    }
}

/// Probe whether the daemon singleton lock is held by another process.
///
/// Thin wrapper around [`daemon_lock_is_held_at`] that uses
/// [`lock_path`]. See that function's docs for the invariant.
#[must_use]
pub fn daemon_lock_is_held() -> bool {
    daemon_lock_is_held_at(&lock_path())
}

/// Probe whether an arbitrary daemon lock file is currently held by a live
/// process.
///
/// Returns `true` when another process holds the exclusive `flock` on
/// `lock_path`, meaning the daemon owning that lock is running. Returns
/// `false` when the lock file is missing or the lock can be acquired
/// (daemon is dead or was never started). The kernel releases `flock` on
/// process death (even `SIGKILL`), so this is immune to PID reuse and stale
/// manifests.
///
/// Used by [`crate::daemon::discovery`] to scan candidate daemon roots
/// without opening every possible manifest path.
#[must_use]
pub fn daemon_lock_is_held_at(lock_path: &Path) -> bool {
    let Ok(file) = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(lock_path)
    else {
        return false;
    };
    match file.try_lock_exclusive() {
        Ok(()) => {
            let _ = file.unlock();
            false
        }
        Err(error) if error.kind() == io::ErrorKind::WouldBlock => true,
        Err(_) => false,
    }
}

/// Load the persisted daemon manifest, if present.
///
/// # Errors
/// Returns `CliError` on parse failures.
pub fn load_manifest() -> Result<Option<DaemonManifest>, CliError> {
    if !manifest_path().is_file() {
        return Ok(None);
    }
    read_json_typed(&manifest_path()).map(Some)
}

/// Load the manifest only when the daemon singleton lock is currently held.
///
/// Stale manifests can remain after forced process termination, so status
/// commands should not treat a manifest file alone as proof that the daemon is
/// online.
///
/// # Errors
/// Returns `CliError` when the manifest cannot be loaded or a stale manifest
/// cannot be removed.
pub fn load_running_manifest() -> Result<Option<DaemonManifest>, CliError> {
    let Some(manifest) = load_manifest()? else {
        return Ok(None);
    };
    if daemon_lock_is_held() {
        return Ok(Some(manifest));
    }
    clear_manifest_for_pid(manifest.pid)?;
    Ok(None)
}

/// Persist the daemon manifest atomically, bumping [`DaemonManifest::revision`]
/// and refreshing [`DaemonManifest::updated_at`] so external watchers can
/// distinguish in-place updates from no-op rewrites.
///
/// Returns the manifest as it was written (with the new revision and
/// timestamp) so callers that need to publish it downstream don't re-read
/// from disk. Existing `let _ = write_manifest(&m)` call sites keep working
/// unchanged.
///
/// Concurrency: writes are serialized by the daemon singleton lock (one
/// writer at a time). Atomic tmp-file + rename guarantees observers never
/// see a partial manifest.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn write_manifest(manifest: &DaemonManifest) -> Result<DaemonManifest, CliError> {
    ensure_daemon_dirs()?;
    let previous_revision = load_manifest().ok().flatten().map_or(0, |m| m.revision);
    let next = DaemonManifest {
        revision: previous_revision.saturating_add(1),
        updated_at: utc_now(),
        ..manifest.clone()
    };
    write_json_pretty(&manifest_path(), &next)?;
    Ok(next)
}

/// Remove the daemon manifest when it still belongs to `pid`.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn clear_manifest_for_pid(pid: u32) -> Result<(), CliError> {
    let path = manifest_path();
    let Some(manifest) = load_manifest()? else {
        return Ok(());
    };
    if manifest.pid != pid || !path.exists() {
        return Ok(());
    }
    fs::remove_file(&path)
        .map_err(|error| CliErrorKind::workflow_io(format!("remove daemon manifest: {error}")))?;
    Ok(())
}

/// Generate and persist a local bearer token with 0600 permissions.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn ensure_auth_token() -> Result<String, CliError> {
    ensure_daemon_dirs()?;
    let path = auth_token_path();
    if path.is_file() {
        return fs_err::read_to_string(&path)
            .map(|token| token.trim().to_string())
            .map_err(|error| {
                CliErrorKind::workflow_io(format!("read daemon token: {error}")).into()
            });
    }

    let token = format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple());
    write_text(&path, &token)?;
    let permissions = fs::Permissions::from_mode(0o600);
    fs::set_permissions(&path, permissions).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "set daemon token permissions: {error}"
        )))
    })?;
    Ok(token)
}

/// Append a daemon-owned audit event.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn append_event(level: &str, message: &str) -> Result<(), CliError> {
    ensure_daemon_dirs()?;
    let path = events_path();
    let event = DaemonAuditEvent {
        recorded_at: utc_now(),
        level: level.to_string(),
        message: message.to_string(),
    };
    let line = serde_json::to_string(&event).map_err(|error| {
        CliError::from(CliErrorKind::workflow_serialize(format!(
            "serialize daemon audit event: {error}"
        )))
    })?;
    let mut file = fs_err::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| CliErrorKind::workflow_io(format!("open daemon events: {error}")))?;
    writeln!(file, "{line}")
        .map_err(|error| CliErrorKind::workflow_io(format!("append daemon event: {error}")).into())
}

/// Read the newest daemon audit events from disk.
///
/// # Errors
/// Returns `CliError` when the audit log cannot be read or parsed.
pub fn read_recent_events(limit: usize) -> Result<Vec<DaemonAuditEvent>, CliError> {
    let path = events_path();
    if limit == 0 || !path.is_file() {
        return Ok(Vec::new());
    }

    let content = fs_err::read_to_string(&path).map_err(|error| {
        CliError::from(CliErrorKind::workflow_io(format!(
            "read daemon events {}: {error}",
            path.display()
        )))
    })?;
    let mut events = Vec::new();
    for line in content.lines().rev() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let event = serde_json::from_str(trimmed).map_err(|error| {
            CliError::from(CliErrorKind::workflow_parse(format!(
                "parse daemon event {}: {error}",
                path.display()
            )))
        })?;
        events.push(event);
        if events.len() == limit {
            break;
        }
    }
    events.reverse();
    Ok(events)
}

/// Build a derived diagnostics snapshot for the local daemon workspace.
///
/// # Errors
/// Returns `CliError` on filesystem or parse failures.
pub fn diagnostics() -> Result<DaemonDiagnostics, CliError> {
    let db_path = daemon_root().join("harness.db");
    let db_size = db_path.metadata().map_or(0, |metadata| metadata.len());
    Ok(DaemonDiagnostics {
        daemon_root: daemon_root().display().to_string(),
        manifest_path: manifest_path().display().to_string(),
        auth_token_path: auth_token_path().display().to_string(),
        auth_token_present: auth_token_path().is_file(),
        events_path: events_path().display().to_string(),
        database_path: db_path.display().to_string(),
        database_size_bytes: db_size,
        last_event: latest_event()?,
    })
}

fn latest_event() -> Result<Option<DaemonAuditEvent>, CliError> {
    Ok(read_recent_events(1)?.pop())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn ensure_auth_token_writes_strict_permissions() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [(
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            )],
            || {
                let token = ensure_auth_token().expect("token");
                assert!(!token.is_empty());
                let metadata = fs::metadata(auth_token_path()).expect("metadata");
                assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
            },
        );
    }

    #[test]
    fn daemon_root_prefers_explicit_daemon_data_home() {
        let tmp = tempdir().expect("tempdir");
        let daemon_data_home = tmp.path().join("daemon-data-home");
        let xdg_data_home = tmp.path().join("xdg-data-home");

        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(daemon_data_home.to_str().expect("utf8 path")),
                ),
                (
                    "XDG_DATA_HOME",
                    Some(xdg_data_home.to_str().expect("utf8 path")),
                ),
            ],
            || {
                assert_eq!(
                    daemon_root(),
                    daemon_data_home.join("harness").join("daemon")
                );
            },
        );
    }

    #[test]
    fn daemon_root_uses_app_group_without_relocating_session_data() {
        let tmp = tempdir().expect("tempdir");

        temp_env::with_vars(
            [
                ("HOME", Some(tmp.path().to_str().expect("utf8 path"))),
                (
                    "HARNESS_HOST_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("XDG_DATA_HOME", None),
                ("HARNESS_DAEMON_DATA_HOME", None),
                ("HARNESS_APP_GROUP_ID", Some("Q498EB36N4.io.harnessmonitor")),
            ],
            || {
                assert_eq!(
                    daemon_root(),
                    tmp.path()
                        .join("Library")
                        .join("Group Containers")
                        .join("Q498EB36N4.io.harnessmonitor")
                        .join("harness")
                        .join("daemon")
                );
                assert_ne!(
                    harness_data_root(),
                    tmp.path()
                        .join("Library")
                        .join("Group Containers")
                        .join("Q498EB36N4.io.harnessmonitor")
                        .join("harness")
                );
            },
        );
    }

    #[test]
    fn manifest_deserializes_legacy_json_without_sandbox_fields() {
        let legacy = r#"{
            "version": "18.14.0",
            "pid": 101,
            "endpoint": "http://127.0.0.1:7070",
            "started_at": "2026-04-01T00:00:00Z",
            "token_path": "/tmp/legacy-token"
        }"#;
        let manifest: DaemonManifest = serde_json::from_str(legacy).expect("legacy deserialize");
        assert_eq!(manifest.version, "18.14.0");
        assert_eq!(manifest.pid, 101);
        assert!(
            !manifest.sandboxed,
            "legacy manifests default to unsandboxed"
        );
        assert!(
            manifest.host_bridge == HostBridgeManifest::default(),
            "legacy manifests default host bridge to an empty snapshot"
        );
        assert_eq!(
            manifest.revision, 0,
            "legacy manifests default revision to zero"
        );
        assert!(
            manifest.updated_at.is_empty(),
            "legacy manifests default updated_at to empty"
        );
    }

    #[test]
    fn manifest_round_trip() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [(
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            )],
            || {
                let manifest = DaemonManifest {
                    version: "14.5.0".into(),
                    pid: 42,
                    endpoint: "http://127.0.0.1:9999".into(),
                    started_at: "2026-03-28T12:00:00Z".into(),
                    token_path: auth_token_path().display().to_string(),
                    sandboxed: false,
                    host_bridge: HostBridgeManifest::default(),
                    revision: 0,
                    updated_at: String::new(),
                };
                write_manifest(&manifest).expect("write");
                let loaded = load_manifest().expect("load").expect("manifest");
                assert_eq!(loaded.endpoint, manifest.endpoint);
                assert_eq!(loaded.pid, 42);
                assert_eq!(loaded.revision, 1, "first write bumps revision to 1");
                assert!(!loaded.updated_at.is_empty(), "updated_at is populated");
            },
        );
    }

    #[test]
    fn singleton_lock_rejects_second_holder() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [(
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            )],
            || {
                let _guard = acquire_singleton_lock().expect("first lock");
                write_manifest(&DaemonManifest {
                    version: env!("CARGO_PKG_VERSION").into(),
                    pid: 4242,
                    endpoint: "http://127.0.0.1:9999".into(),
                    started_at: "2026-04-04T07:00:00Z".into(),
                    token_path: auth_token_path().display().to_string(),
                    sandboxed: false,
                    host_bridge: HostBridgeManifest::default(),
                    revision: 0,
                    updated_at: String::new(),
                })
                .expect("manifest");

                let error = acquire_singleton_lock().expect_err("second lock should fail");
                let message = error.to_string();
                assert!(message.contains("daemon already running"));
                assert!(message.contains("4242"));
                assert!(message.contains("127.0.0.1:9999"));
            },
        );
    }

    #[test]
    fn clear_manifest_for_pid_only_removes_owned_manifest() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [(
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            )],
            || {
                write_manifest(&DaemonManifest {
                    version: env!("CARGO_PKG_VERSION").into(),
                    pid: 777,
                    endpoint: "http://127.0.0.1:7777".into(),
                    started_at: "2026-04-04T07:05:00Z".into(),
                    token_path: auth_token_path().display().to_string(),
                    sandboxed: false,
                    host_bridge: HostBridgeManifest::default(),
                    revision: 0,
                    updated_at: String::new(),
                })
                .expect("manifest");

                clear_manifest_for_pid(778).expect("skip foreign pid");
                assert!(
                    manifest_path().exists(),
                    "foreign pid should not clear manifest"
                );

                clear_manifest_for_pid(777).expect("clear owned manifest");
                assert!(!manifest_path().exists(), "owned pid should clear manifest");
            },
        );
    }

    #[test]
    fn load_running_manifest_clears_stale_manifest_when_lock_is_free() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [(
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            )],
            || {
                write_manifest(&DaemonManifest {
                    version: env!("CARGO_PKG_VERSION").into(),
                    pid: 9191,
                    endpoint: "http://127.0.0.1:9191".into(),
                    started_at: "2026-04-10T07:05:00Z".into(),
                    token_path: auth_token_path().display().to_string(),
                    sandboxed: false,
                    host_bridge: HostBridgeManifest::default(),
                    revision: 0,
                    updated_at: String::new(),
                })
                .expect("manifest");

                let manifest = load_running_manifest().expect("load running manifest");

                assert!(manifest.is_none(), "stale manifest should be hidden");
                assert!(
                    !manifest_path().exists(),
                    "stale manifest should be removed"
                );
            },
        );
    }

    #[test]
    fn diagnostics_include_latest_event_and_database_path() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [(
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            )],
            || {
                append_event("info", "daemon booted").expect("append event");

                let diagnostics = diagnostics().expect("diagnostics");
                assert!(diagnostics.auth_token_path.ends_with("auth-token"));
                assert!(diagnostics.database_path.ends_with("harness.db"));
                assert_eq!(diagnostics.database_size_bytes, 0);
                assert_eq!(
                    diagnostics.last_event.expect("latest event").message,
                    "daemon booted"
                );
            },
        );
    }

    #[test]
    fn read_recent_events_returns_last_entries_in_order() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [(
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            )],
            || {
                append_event("info", "daemon booted").expect("append event");
                append_event("warn", "stalled session").expect("append event");
                append_event("info", "refresh complete").expect("append event");

                let events = read_recent_events(2).expect("recent events");

                assert_eq!(events.len(), 2);
                assert_eq!(events[0].message, "stalled session");
                assert_eq!(events[1].message, "refresh complete");
            },
        );
    }

    /// Teardown helper: clears the process-global daemon root override.
    /// Every test that mutates the override MUST call this on exit, even
    /// on assertion failure paths, because tests run single-threaded and
    /// leaked overrides poison downstream tests.
    fn reset_override_for_tests() {
        set_daemon_root_override(None);
    }

    #[test]
    fn daemon_root_override_takes_precedence_over_env() {
        let tmp = tempdir().expect("tempdir");
        let override_root = tmp.path().join("forced");
        temp_env::with_vars(
            [
                ("HARNESS_DAEMON_DATA_HOME", None::<&str>),
                ("HARNESS_APP_GROUP_ID", None),
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
            ],
            || {
                reset_override_for_tests();
                set_daemon_root_override(Some(override_root.clone()));
                assert_eq!(daemon_root(), override_root);
                // default_daemon_root() must ignore the override so discovery
                // can still reason about "what would we pick without adoption".
                assert_ne!(default_daemon_root(), override_root);
                reset_override_for_tests();
            },
        );
    }

    #[test]
    fn daemon_root_override_clears_when_set_to_none() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                ("HARNESS_DAEMON_DATA_HOME", None::<&str>),
                ("HARNESS_APP_GROUP_ID", None),
                (
                    "XDG_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
            ],
            || {
                reset_override_for_tests();
                set_daemon_root_override(Some(tmp.path().join("ignored")));
                set_daemon_root_override(None);
                assert_eq!(daemon_root(), default_daemon_root());
                reset_override_for_tests();
            },
        );
    }

    #[test]
    fn write_manifest_bumps_revision_monotonically() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [(
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            )],
            || {
                let base = DaemonManifest {
                    version: env!("CARGO_PKG_VERSION").into(),
                    pid: 123,
                    endpoint: "http://127.0.0.1:0".into(),
                    started_at: "2026-04-11T00:00:00Z".into(),
                    token_path: auth_token_path().display().to_string(),
                    sandboxed: false,
                    host_bridge: HostBridgeManifest::default(),
                    revision: 0,
                    updated_at: String::new(),
                };
                let first = write_manifest(&base).expect("first write");
                assert_eq!(first.revision, 1);
                assert!(!first.updated_at.is_empty());

                let second = write_manifest(&base).expect("second write");
                assert_eq!(second.revision, 2);

                let third = write_manifest(&base).expect("third write");
                assert_eq!(third.revision, 3);

                // Loading from disk returns the bumped values.
                let loaded = load_manifest().expect("load").expect("manifest");
                assert_eq!(loaded.revision, 3);
                assert!(!loaded.updated_at.is_empty());
            },
        );
    }

    #[test]
    fn daemon_lock_is_held_at_returns_false_for_missing_lock_file() {
        let tmp = tempdir().expect("tempdir");
        let missing = tmp.path().join("daemon.lock");
        assert!(!daemon_lock_is_held_at(&missing));
    }

    #[test]
    fn daemon_lock_is_held_at_returns_false_for_unlocked_file() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("daemon.lock");
        fs::write(&path, "").expect("create empty lock file");
        assert!(!daemon_lock_is_held_at(&path));
    }

    #[test]
    fn daemon_lock_is_held_at_returns_true_for_actively_held_lock() {
        let tmp = tempdir().expect("tempdir");
        let path = tmp.path().join("daemon.lock");
        let holder = fs::OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .truncate(false)
            .open(&path)
            .expect("open lock");
        holder.try_lock_exclusive().expect("take flock");
        assert!(daemon_lock_is_held_at(&path));
        // Keep `holder` alive until here; dropping it releases the flock.
        drop(holder);
        assert!(!daemon_lock_is_held_at(&path));
    }
}
