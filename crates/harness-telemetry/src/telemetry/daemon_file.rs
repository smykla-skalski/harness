use std::io::{self, Write as _};
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
use super::daemon_log_rotation::{BoundedLogFile, LogFormat, diagnostic_event};

pub(super) fn layer<S>(
    service: RuntimeService,
    use_json_format: bool,
    show_observability_fields: bool,
) -> Option<Box<dyn Layer<S> + Send + Sync + 'static>>
where
    S: Subscriber + for<'span> LookupSpan<'span>,
{
    if !matches!(service, RuntimeService::Daemon | RuntimeService::Bridge) {
        return None;
    }

    let writer = RuntimeLogWriter {
        service,
        format: if use_json_format {
            LogFormat::Json
        } else {
            LogFormat::Text
        },
    };

    match (use_json_format, show_observability_fields) {
        (true, true) => Some(Box::new(fmt::layer().json().with_writer(writer))),
        (true, false) => Some(Box::new(
            fmt::layer()
                .json()
                .fmt_fields(FilteredJsonFields::new())
                .with_writer(writer),
        )),
        (false, true) => Some(Box::new(
            fmt::layer()
                .with_writer(writer)
                .with_target(false)
                .with_timer(ChronoUtc::rfc_3339()),
        )),
        (false, false) => Some(Box::new(
            fmt::layer()
                .fmt_fields(FilteredDefaultFields::new())
                .with_writer(writer)
                .with_target(false)
                .with_timer(ChronoUtc::rfc_3339()),
        )),
    }
}

#[derive(Debug, Clone)]
struct RuntimeLogWriter {
    service: RuntimeService,
    format: LogFormat,
}

impl<'writer> MakeWriter<'writer> for RuntimeLogWriter {
    type Writer = BoundedLogFile;

    fn make_writer(&'writer self) -> Self::Writer {
        BoundedLogFile::open(runtime_log_path(self.service), self.format)
    }
}

/// Persist an initialization failure before the tracing subscriber exists.
///
/// # Errors
/// Returns an error when the bounded daemon log cannot be written.
pub fn write_runtime_fallback_error(service: RuntimeService, message: &str) -> io::Result<()> {
    if !matches!(service, RuntimeService::Daemon | RuntimeService::Bridge) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "bounded fallback logging is only available to long-lived services",
        ));
    }
    let format = if normalized_env_value("HARNESS_LOG_FORMAT").as_deref() == Some("json") {
        LogFormat::Json
    } else {
        LogFormat::Text
    };
    let mut writer = BoundedLogFile::open(runtime_log_path(service), format);
    writer.write_all(&diagnostic_event(format, "ERROR", message))?;
    writer.flush()
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
/// Cross-crate sync plumbing for `src/daemon/state/paths.rs`, not a supported
/// public API - hidden from docs so it doesn't read as one.
///
/// # Panics
/// Panics only if the mirror mutex is poisoned, which indicates another
/// thread panicked while holding it.
#[doc(hidden)]
pub fn observe_daemon_root_override(path: Option<PathBuf>) {
    *DAEMON_ROOT_OVERRIDE
        .lock()
        .expect("daemon root override mirror mutex poisoned") = path;
}

/// Mirror the canonical daemon-ownership override the same way `true` means
/// the external ownership subtree, matching `DaemonOwnership::External`.
///
/// Cross-crate sync plumbing for `src/daemon/state/ownership.rs`, not a
/// supported public API - hidden from docs so it doesn't read as one.
///
/// # Panics
/// Panics only if the mirror mutex is poisoned, which indicates another
/// thread panicked while holding it.
#[doc(hidden)]
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

fn runtime_log_path(service: RuntimeService) -> PathBuf {
    let file_name = match service {
        RuntimeService::Bridge => "bridge.log",
        _ => "daemon.log",
    };
    daemon_log_path().with_file_name(file_name)
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
    use std::io::Write as _;

    use tempfile::tempdir;
    use tracing_subscriber::fmt::writer::MakeWriter as _;

    use super::{
        LogFormat, RuntimeLogWriter, RuntimeService, daemon_log_path,
        observe_daemon_ownership_override, observe_daemon_root_override,
        write_runtime_fallback_error,
    };
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

    #[test]
    fn startup_fallback_is_a_bounded_valid_json_event() {
        let _scope = OverrideScope::new();
        let root = tempdir().expect("tempdir");
        observe_daemon_root_override(Some(root.path().to_path_buf()));

        temp_env::with_var("HARNESS_LOG_FORMAT", Some("json"), || {
            write_runtime_fallback_error(
                RuntimeService::Daemon,
                "subscriber initialization failed",
            )
            .expect("fallback event");
        });

        let event =
            std::fs::read_to_string(root.path().join("daemon.log")).expect("fallback daemon log");
        let event: serde_json::Value = serde_json::from_str(event.trim()).expect("valid JSON");
        assert_eq!(event["level"], "ERROR");
        assert_eq!(
            event["fields"]["message"],
            "subscriber initialization failed"
        );
    }

    #[test]
    fn bridge_fallback_uses_its_own_bounded_log() {
        let _scope = OverrideScope::new();
        let root = tempdir().expect("tempdir");
        observe_daemon_root_override(Some(root.path().to_path_buf()));

        write_runtime_fallback_error(RuntimeService::Bridge, "bridge startup failed")
            .expect("bridge fallback");

        let event =
            std::fs::read_to_string(root.path().join("bridge.log")).expect("bridge fallback log");
        assert!(event.contains("bridge startup failed"));
        assert!(!root.path().join("daemon.log").exists());
    }

    #[test]
    fn writer_resolves_daemon_root_after_layer_construction() {
        let _scope = OverrideScope::new();
        let root = tempdir().expect("tempdir");
        let writer = RuntimeLogWriter {
            service: RuntimeService::Bridge,
            format: LogFormat::Text,
        };
        observe_daemon_root_override(Some(root.path().to_path_buf()));

        writer
            .make_writer()
            .write_all(b"adopted root event")
            .expect("bounded bridge log");

        assert_eq!(
            std::fs::read(root.path().join("bridge.log")).expect("adopted bridge log"),
            b"adopted root event"
        );
    }
}
