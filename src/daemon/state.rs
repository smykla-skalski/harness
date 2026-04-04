use std::fs;
use std::io::{self, Write as _};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

use fs2::FileExt;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::errors::{CliError, CliErrorKind};
use crate::infra::io::{read_json_typed, write_json_pretty, write_text};
use crate::workspace::{dirs_home, harness_data_root, utc_now};

const LAUNCH_AGENTS_DIR: &str = "LaunchAgents";
const CURRENT_LAUNCH_AGENT_PLIST: &str = "io.harness.daemon.plist";
const LEGACY_LAUNCH_AGENT_PLIST: &str = "io.harness.monitor.daemon.plist";
const DAEMON_LOCK_FILE: &str = "daemon.lock";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonManifest {
    pub version: String,
    pub pid: u32,
    pub endpoint: String,
    pub started_at: String,
    pub token_path: String,
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
    harness_data_root().join("daemon")
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

/// Persist the daemon manifest atomically.
///
/// # Errors
/// Returns `CliError` on filesystem failures.
pub fn write_manifest(manifest: &DaemonManifest) -> Result<(), CliError> {
    ensure_daemon_dirs()?;
    write_json_pretty(&manifest_path(), manifest)
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
                };
                write_manifest(&manifest).expect("write");
                let loaded = load_manifest().expect("load").expect("manifest");
                assert_eq!(loaded.endpoint, manifest.endpoint);
                assert_eq!(loaded.pid, 42);
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
}
