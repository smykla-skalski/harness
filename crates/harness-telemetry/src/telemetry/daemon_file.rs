use std::fs::{File, OpenOptions};
use std::io;
use std::path::PathBuf;
use std::sync::Mutex;

use tracing::Subscriber;
use tracing_subscriber::Layer;
use tracing_subscriber::fmt;
use tracing_subscriber::fmt::time::ChronoUtc;
use tracing_subscriber::fmt::writer::MakeWriter;
use tracing_subscriber::registry::LookupSpan;

use crate::workspace::{harness_data_root, normalized_env_value};

use super::config::RuntimeService;
use super::console_fields::{FilteredDefaultFields, FilteredJsonFields};

pub(super) fn layer<S>(
    service: RuntimeService,
    use_json_format: bool,
    show_observability_fields: bool,
) -> Option<Box<dyn Layer<S> + Send + Sync + 'static>>
where
    S: Subscriber + for<'span> LookupSpan<'span>,
{
    if service != RuntimeService::Daemon {
        return None;
    }

    match (use_json_format, show_observability_fields) {
        (true, true) => Some(Box::new(fmt::layer().json().with_writer(DaemonLogWriter))),
        (true, false) => Some(Box::new(
            fmt::layer()
                .json()
                .fmt_fields(FilteredJsonFields::new())
                .with_writer(DaemonLogWriter),
        )),
        (false, true) => Some(Box::new(
            fmt::layer()
                .with_writer(DaemonLogWriter)
                .with_target(false)
                .with_timer(ChronoUtc::rfc_3339()),
        )),
        (false, false) => Some(Box::new(
            fmt::layer()
                .fmt_fields(FilteredDefaultFields::new())
                .with_writer(DaemonLogWriter)
                .with_target(false)
                .with_timer(ChronoUtc::rfc_3339()),
        )),
    }
}

#[derive(Debug, Clone, Copy)]
struct DaemonLogWriter;

impl<'writer> MakeWriter<'writer> for DaemonLogWriter {
    type Writer = DaemonLogFile;

    fn make_writer(&'writer self) -> Self::Writer {
        DaemonLogFile::open()
    }
}

enum DaemonLogFile {
    File(File),
    Sink(io::Sink),
}

impl DaemonLogFile {
    fn open() -> Self {
        let path = daemon_log_path();
        if let Some(parent) = path.parent()
            && std::fs::create_dir_all(parent).is_ok()
            && let Ok(file) = OpenOptions::new().create(true).append(true).open(path)
        {
            return Self::File(file);
        }
        Self::Sink(io::sink())
    }
}

impl io::Write for DaemonLogFile {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        match self {
            Self::File(file) => file.write(bytes),
            Self::Sink(sink) => sink.write(bytes),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::File(file) => file.flush(),
            Self::Sink(sink) => sink.flush(),
        }
    }
}

// `src/daemon/state` (`ScopedDaemonRootOverride`/`ScopedOwnershipOverride`) is
// the canonical resolution the rest of the daemon process uses for the CLI's
// `--daemon-root` flag and daemon discovery, but this crate can't depend on
// `harness-daemon`/`harness-daemon-client` to read it directly - that's the
// wrong direction in the dependency graph. The daemon side already depends on
// this crate, so it mirrors every override mutation here instead; see the
// call sites in `src/daemon/state/paths.rs` and `src/daemon/state/ownership.rs`.
static DAEMON_ROOT_OVERRIDE: Mutex<Option<PathBuf>> = Mutex::new(None);
static DAEMON_OWNERSHIP_OVERRIDE: Mutex<Option<bool>> = Mutex::new(None);

/// Mirror the canonical daemon-root override so this crate's independent
/// daemon-log path resolution agrees with the rest of the daemon process
/// about where its root is. `None` clears the override.
///
/// # Panics
/// Panics only if the mirror mutex is poisoned, which indicates another
/// thread panicked while holding it.
pub fn observe_daemon_root_override(path: Option<PathBuf>) {
    *DAEMON_ROOT_OVERRIDE
        .lock()
        .expect("daemon root override mirror mutex poisoned") = path;
}

/// Mirror the canonical daemon-ownership override the same way `true` means
/// the external ownership subtree, matching `DaemonOwnership::External`.
///
/// # Panics
/// Panics only if the mirror mutex is poisoned, which indicates another
/// thread panicked while holding it.
pub fn observe_daemon_ownership_override(external: Option<bool>) {
    *DAEMON_OWNERSHIP_OVERRIDE
        .lock()
        .expect("daemon ownership override mirror mutex poisoned") = external;
}

fn daemon_root_override() -> Option<PathBuf> {
    DAEMON_ROOT_OVERRIDE
        .lock()
        .expect("daemon root override mirror mutex poisoned")
        .clone()
}

fn daemon_ownership_override() -> Option<bool> {
    *DAEMON_OWNERSHIP_OVERRIDE
        .lock()
        .expect("daemon ownership override mirror mutex poisoned")
}

fn daemon_log_path() -> PathBuf {
    // A root override replaces the whole resolution, ownership subdir
    // included - it mirrors `state::daemon_root()`, which returns the
    // override verbatim rather than rejoining it under `managed`/`external`.
    if let Some(root) = daemon_root_override() {
        return root.join("daemon.log");
    }
    daemon_base_dir()
        .join(daemon_ownership())
        .join("daemon.log")
}

fn daemon_base_dir() -> PathBuf {
    if let Some(root) = normalized_env_value("HARNESS_DAEMON_DATA_HOME") {
        return PathBuf::from(root).join("harness").join("daemon");
    }
    if let Some(group_id) = normalized_env_value("HARNESS_APP_GROUP_ID") {
        return home_dir()
            .join("Library")
            .join("Group Containers")
            .join(group_id)
            .join("harness")
            .join("daemon");
    }
    harness_data_root().join("daemon")
}

fn daemon_ownership() -> &'static str {
    let external = daemon_ownership_override().unwrap_or_else(|| {
        normalized_env_value("HARNESS_DAEMON_OWNERSHIP")
            .is_some_and(|value| value.eq_ignore_ascii_case("external"))
    });
    if external { "external" } else { "managed" }
}

fn home_dir() -> PathBuf {
    normalized_env_value("HARNESS_HOST_HOME")
        .map(PathBuf::from)
        .or_else(|| user_dirs::home_dir().ok())
        .or_else(|| normalized_env_value("HOME").map(PathBuf::from))
        .unwrap_or_else(std::env::temp_dir)
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::{daemon_log_path, observe_daemon_ownership_override, observe_daemon_root_override};
    use crate::telemetry::telemetry_test_guard;

    /// Serializes access to the module-level override mirrors and always
    /// clears them on drop, so one test's override never leaks into the
    /// next when tests run in the same process (plain `cargo test`, not
    /// nextest's per-test process isolation).
    struct OverrideScope {
        _serialize: std::sync::MutexGuard<'static, ()>,
    }

    impl OverrideScope {
        fn new() -> Self {
            let serialize = telemetry_test_guard();
            observe_daemon_root_override(None);
            observe_daemon_ownership_override(None);
            Self {
                _serialize: serialize,
            }
        }
    }

    impl Drop for OverrideScope {
        fn drop(&mut self) {
            observe_daemon_root_override(None);
            observe_daemon_ownership_override(None);
        }
    }

    #[test]
    fn root_override_replaces_env_resolution_entirely() {
        let _scope = OverrideScope::new();
        let root = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                // If the override were ignored, resolution would fall
                // through to these and land somewhere else entirely - that
                // was the original bug: a process running under
                // `ScopedDaemonRootOverride` still wrote its daemon.log
                // under the env-derived default location.
                ("HARNESS_DAEMON_DATA_HOME", Some("/should-not-be-used")),
                ("HARNESS_DAEMON_OWNERSHIP", Some("managed")),
            ],
            || {
                observe_daemon_root_override(Some(root.path().to_path_buf()));
                assert_eq!(daemon_log_path(), root.path().join("daemon.log"));
            },
        );
    }

    #[test]
    fn ownership_override_takes_priority_over_env_var() {
        let _scope = OverrideScope::new();
        let data_home = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(data_home.path().to_str().expect("utf8 path")),
                ),
                // The env var says managed; the override, set as if by
                // `ScopedOwnershipOverride::set(Some(DaemonOwnership::External))`,
                // must win - that priority order is what the original bug
                // dropped.
                ("HARNESS_DAEMON_OWNERSHIP", Some("managed")),
            ],
            || {
                observe_daemon_ownership_override(Some(true));
                let expected = data_home
                    .path()
                    .join("harness")
                    .join("daemon")
                    .join("external")
                    .join("daemon.log");
                assert_eq!(daemon_log_path(), expected);
            },
        );
    }

    #[test]
    fn no_override_falls_back_to_env_resolution() {
        let _scope = OverrideScope::new();
        let data_home = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(data_home.path().to_str().expect("utf8 path")),
                ),
                ("HARNESS_DAEMON_OWNERSHIP", Some("external")),
            ],
            || {
                let expected = data_home
                    .path()
                    .join("harness")
                    .join("daemon")
                    .join("external")
                    .join("daemon.log");
                assert_eq!(daemon_log_path(), expected);
            },
        );
    }
}
