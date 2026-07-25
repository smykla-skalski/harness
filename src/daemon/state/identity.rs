//! The identity a daemon reports to the clients that connect to it.
//!
//! A client needs to tell one daemon from another before it has any record of
//! either, and it needs the answer to survive a restart, an upgrade, and a move
//! to a new address. None of the values the daemon already reports do that:
//! version, pid, endpoint, and the started-at epoch all change under it.

use std::fs::File;
use std::path::Path;
#[cfg(target_os = "macos")]
use std::process::Command;
use std::sync::LazyLock;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use harness_kernel::errors::{CliError, CliErrorKind, io_for};
use crate::infra::io::{read_json_typed, write_json_pretty};
use crate::infra::persistence::flock::{FlockErrorContext, with_exclusive_flock};
use crate::workspace::{normalized_env_value, utc_now};

use super::{ensure_daemon_dirs, identity_path};

/// Seeds the reported name when nothing has been set through
/// [`set_daemon_name`]. Deployments that template a unit file set this instead
/// of running a second command after install.
pub const DAEMON_NAME_ENV: &str = "HARNESS_DAEMON_NAME";
/// Overrides the host signal the identity is bound to. Set this per host where
/// the daemon cannot read a machine identifier of its own - notably a
/// sandboxed macOS daemon, which cannot spawn `ioreg` - because without it
/// that host cannot tell a restored copy from its own directory. Any value
/// that differs between machines and survives a restart will do.
pub const DAEMON_HOST_FINGERPRINT_ENV: &str = "HARNESS_DAEMON_HOST_FINGERPRINT";

const FALLBACK_DAEMON_NAME: &str = "harness-daemon";
const MAX_DAEMON_NAME_CHARS: usize = 64;
const MACHINE_ID_FILES: &[&str] = &["/etc/machine-id", "/var/lib/dbus/machine-id"];

/// What a daemon answers when a client asks who it is.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaemonIdentity {
    /// Stable across restarts, upgrades, and endpoint changes. Clients key
    /// their own per-daemon records on this.
    pub daemon_id: String,
    /// Shown to a person. Not unique, and not safe to key anything on.
    pub name: String,
}

/// On-disk form. `host_fingerprint` is what stops a daemon directory that was
/// restored from another machine's backup from answering with that machine's
/// id: a fingerprint that no longer matches the host mints a new one.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct PersistedDaemonIdentity {
    daemon_id: String,
    created_at: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    host_fingerprint: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    name: Option<String>,
}

impl PersistedDaemonIdentity {
    fn mint(host_fingerprint: Option<String>) -> Self {
        Self {
            daemon_id: Uuid::new_v4().to_string(),
            created_at: utc_now(),
            host_fingerprint,
            name: None,
        }
    }

    fn into_identity(self) -> DaemonIdentity {
        DaemonIdentity {
            daemon_id: self.daemon_id,
            name: self.name.unwrap_or_else(default_daemon_name),
        }
    }
}

/// Read this daemon's identity, minting one when the daemon root has none it
/// can claim.
///
/// # Errors
/// Returns `CliError` when the identity file exists but cannot be parsed, or
/// when a new one cannot be written.
pub fn ensure_daemon_identity() -> Result<DaemonIdentity, CliError> {
    let path = identity_path();
    let fingerprint = host_fingerprint();
    if let Some(record) = read_identity(&path)?
        && belongs_to_host(&record, fingerprint.as_deref())
    {
        return Ok(record.into_identity());
    }
    ensure_daemon_dirs()?;
    with_identity_lock(&path, || {
        Ok(current_or_minted(&path, fingerprint)?.into_identity())
    })
}

/// Read the identity for reporting to a client, without creating one.
///
/// Read per report rather than cached so a rename from another process reaches
/// connected clients without a daemon restart. `None` means this daemon root
/// has no identity yet, which a serving daemon has already ruled out at
/// startup.
///
/// # Errors
/// Returns `CliError` when the identity file exists but cannot be parsed.
pub fn reported_daemon_identity() -> Result<Option<DaemonIdentity>, CliError> {
    Ok(read_identity(&identity_path())?.map(PersistedDaemonIdentity::into_identity))
}

/// Set the name this daemon reports, replacing any earlier one.
///
/// # Errors
/// Returns `CliError` when the name is blank, over-long, or carries control
/// characters, and when the identity file cannot be read or written.
pub fn set_daemon_name(name: &str) -> Result<DaemonIdentity, CliError> {
    let name = normalize_daemon_name(name)?;
    let path = identity_path();
    let fingerprint = host_fingerprint();
    ensure_daemon_dirs()?;
    with_identity_lock(&path, || {
        let mut record = current_or_minted(&path, fingerprint)?;
        record.name = Some(name);
        write_identity(&path, &record)?;
        Ok(record.into_identity())
    })
}

/// Resolve the stored identity, writing a fresh one when this host has none it
/// can claim. Callers hold the identity lock.
fn current_or_minted(
    path: &Path,
    fingerprint: Option<String>,
) -> Result<PersistedDaemonIdentity, CliError> {
    if let Some(record) = read_identity(path)?
        && belongs_to_host(&record, fingerprint.as_deref())
    {
        return Ok(record);
    }
    // The operator-set name goes with the id it belonged to. Carrying it onto a
    // restored copy would leave two live daemons answering to the same name.
    let record = PersistedDaemonIdentity::mint(fingerprint);
    write_identity(path, &record)?;
    Ok(record)
}

/// A record only fails the check when both sides know their host and disagree.
///
/// A host that offers no machine identifier cannot prove the directory is its
/// own, and rejecting on that would mint a new id on every read - so restore
/// detection is off there, and a copied directory keeps answering with the id
/// it was copied with. [`DAEMON_HOST_FINGERPRINT_ENV`] is how such a host opts
/// back in.
fn belongs_to_host(record: &PersistedDaemonIdentity, current: Option<&str>) -> bool {
    match (record.host_fingerprint.as_deref(), current) {
        (Some(stored), Some(current)) => stored == current,
        _ => true,
    }
}

fn read_identity(path: &Path) -> Result<Option<PersistedDaemonIdentity>, CliError> {
    if !path.is_file() {
        return Ok(None);
    }
    read_json_typed::<PersistedDaemonIdentity>(path).map(Some)
}

/// Synced before returning. An id that a crash loses is an id the next start
/// mints again, and every client that had recorded the old one is looking at a
/// daemon it can no longer recognize.
fn write_identity(path: &Path, record: &PersistedDaemonIdentity) -> Result<(), CliError> {
    write_json_pretty(path, record)?;
    sync_path(path, "sync daemon identity")?;
    match path.parent() {
        Some(parent) => sync_path(parent, "sync daemon identity parent"),
        None => Ok(()),
    }
}

fn sync_path(path: &Path, context: &str) -> Result<(), CliError> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|error| io_for(context, path, &error).into())
}

fn with_identity_lock<T>(
    path: &Path,
    action: impl FnOnce() -> Result<T, CliError>,
) -> Result<T, CliError> {
    let lock_path = path.with_extension("json.lock");
    with_exclusive_flock(
        &lock_path,
        FlockErrorContext::new("daemon identity"),
        action,
    )
}

fn normalize_daemon_name(name: &str) -> Result<String, CliError> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(CliErrorKind::usage_error("daemon name must not be blank").into());
    }
    if trimmed.chars().any(char::is_control) {
        return Err(
            CliErrorKind::usage_error("daemon name must not contain control characters").into(),
        );
    }
    if trimmed.chars().count() > MAX_DAEMON_NAME_CHARS {
        return Err(CliErrorKind::usage_error(format!(
            "daemon name must be {MAX_DAEMON_NAME_CHARS} characters or fewer"
        ))
        .into());
    }
    Ok(trimmed.to_owned())
}

fn default_daemon_name() -> String {
    normalized_env_value(DAEMON_NAME_ENV)
        .or_else(|| HOST_DISPLAY_NAME.clone())
        .and_then(|value| normalize_daemon_name(&value).ok())
        .unwrap_or_else(|| FALLBACK_DAEMON_NAME.to_owned())
}

/// Hashed rather than stored raw: the identity file travels in backups and
/// support bundles, and the host identifier is not ours to hand out.
fn host_fingerprint() -> Option<String> {
    host_machine_id().map(|value| hex::encode(Sha256::digest(value.as_bytes())))
}

fn host_machine_id() -> Option<String> {
    normalized_env_value(DAEMON_HOST_FINGERPRINT_ENV).or_else(|| HOST_MACHINE_ID.clone())
}

/// Asking the host who it is costs a subprocess on macOS, and an unnamed
/// daemon resolves its default name on every health report. Neither answer
/// changes while the process runs, so both are read once. The environment
/// overrides stay live in front of these.
static HOST_MACHINE_ID: LazyLock<Option<String>> = LazyLock::new(|| {
    MACHINE_ID_FILES
        .iter()
        .find_map(|path| read_trimmed_file(Path::new(path)))
        .or_else(platform_machine_id)
});

static HOST_DISPLAY_NAME: LazyLock<Option<String>> = LazyLock::new(host_display_name);

#[cfg(target_os = "macos")]
fn platform_machine_id() -> Option<String> {
    // macOS keeps no machine-id file; IOPlatformUUID is its equivalent. A
    // sandboxed daemon cannot spawn ioreg, and then this host simply has no
    // fingerprint and keeps whatever identity its directory carries.
    let output = Command::new("ioreg")
        .args(["-rd1", "-c", "IOPlatformExpertDevice"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    text.lines()
        .find_map(|line| quoted_value(line, "\"IOPlatformUUID\""))
}

#[cfg(not(target_os = "macos"))]
fn platform_machine_id() -> Option<String> {
    None
}

#[cfg(target_os = "macos")]
fn host_display_name() -> Option<String> {
    // ComputerName is what the person named the Mac; the hostname is a
    // network-derived approximation of it.
    let output = Command::new("scutil")
        .args(["--get", "ComputerName"])
        .output()
        .ok()?;
    let name = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (!name.is_empty()).then_some(name)
}

#[cfg(not(target_os = "macos"))]
fn host_display_name() -> Option<String> {
    read_trimmed_file(Path::new("/etc/hostname"))
        .or_else(|| read_trimmed_file(Path::new("/proc/sys/kernel/hostname")))
}

#[cfg(target_os = "macos")]
fn quoted_value(line: &str, key: &str) -> Option<String> {
    let rest = line.split_once(key)?.1;
    let opening = rest.find('"')?;
    let value = &rest[opening + 1..];
    let closing = value.find('"')?;
    Some(value[..closing].to_owned())
}

fn read_trimmed_file(path: &Path) -> Option<String> {
    let text = fs_err::read_to_string(path).ok()?;
    let trimmed = text.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}
