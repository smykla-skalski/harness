#![deny(unsafe_code)]

use std::sync::OnceLock;

use tracing::Level;
use tracing_subscriber::EnvFilter;
use tracing_subscriber::reload;

pub mod agents;
pub mod app;
#[cfg(test)]
mod codec;
pub mod create;
pub mod daemon;
pub mod errors;
pub mod feature_flags;
pub(crate) mod git;
pub mod hooks;
pub mod infra;
pub mod kernel;
pub(crate) mod manifests;
pub mod mcp;
pub mod observe;
pub(crate) mod platform;
pub mod run;
pub mod sandbox;
pub mod session;
pub mod setup;
pub(crate) mod suite_defaults;
pub mod telemetry;
pub mod workspace;

include!(concat!(env!("OUT_DIR"), "/file_length_enforcement.rs"));

/// Handle type for runtime log filter reloading.
pub type LogFilterHandle = reload::Handle<EnvFilter, tracing_subscriber::Registry>;

/// Default log level for harness runtime diagnostics.
pub const DEFAULT_LOG_LEVEL: &str = "info";

/// Default filter directive used when `RUST_LOG` is not set.
pub const DEFAULT_LOG_FILTER_DIRECTIVE: &str = "harness=info";

/// Default level for high-volume daemon activity logs such as requests and pushes.
pub const DAEMON_ACTIVITY_LOG_LEVEL: Level = Level::DEBUG;

static LOG_FILTER_HANDLE: OnceLock<LogFilterHandle> = OnceLock::new();

/// Store the global log filter reload handle.
///
/// Called once during subscriber initialization in `main()`.
pub fn set_log_filter_handle(handle: LogFilterHandle) {
    let _ = LOG_FILTER_HANDLE.set(handle);
}

/// Access the global log filter reload handle.
///
/// Returns `None` before the tracing subscriber has been initialized.
#[must_use]
pub fn log_filter_handle() -> Option<&'static LogFilterHandle> {
    LOG_FILTER_HANDLE.get()
}

/// Build the default tracing filter used when no explicit env override exists.
#[must_use]
pub fn default_log_filter() -> EnvFilter {
    EnvFilter::new(DEFAULT_LOG_FILTER_DIRECTIVE)
}

/// Resolve the active tracing filter from `RUST_LOG`, falling back to the
/// repo default when the environment does not provide one.
#[must_use]
pub fn resolved_log_filter_from_env() -> EnvFilter {
    EnvFilter::try_from_default_env().unwrap_or_else(|_| default_log_filter())
}

/// Resolve the active tracing filter for a specific runtime service.
///
/// Daemon processes also consult the persisted daemon runtime config when
/// `RUST_LOG` is unset so user-selected log levels survive launch-agent restarts.
///
/// # Errors
/// Returns `CliError` only when building a validated persisted daemon filter
/// directive unexpectedly fails.
pub fn resolved_log_filter_for_service(
    service: telemetry::RuntimeService,
) -> Result<EnvFilter, errors::CliError> {
    if let Ok(filter) = EnvFilter::try_from_default_env() {
        return Ok(filter);
    }

    if matches!(service, telemetry::RuntimeService::Daemon)
        && let Some(level) = advisory_persisted_daemon_log_level()
    {
        let directive = format!("harness={level}");
        return EnvFilter::try_new(&directive).map_err(|error| {
            errors::CliErrorKind::workflow_parse(format!(
                "parse persisted daemon log filter '{directive}': {error}"
            ))
            .into()
        });
    }

    Ok(default_log_filter())
}

fn advisory_persisted_daemon_log_level() -> Option<String> {
    match daemon::state::load_persisted_log_level() {
        Ok(level) => level,
        Err(error) => {
            daemon::state::append_event_best_effort(
                "warn",
                &format!(
                    "ignored persisted daemon log config {}; using {}: {error}",
                    daemon::state::config_path().display(),
                    DEFAULT_LOG_FILTER_DIRECTIVE
                ),
            );
            None
        }
    }
}

#[cfg(test)]
mod logging_tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn default_log_filter_uses_info() {
        assert_eq!(default_log_filter().to_string(), "harness=info");
    }

    #[test]
    fn resolved_log_filter_falls_back_to_info_when_rust_log_is_unset() {
        temp_env::with_var_unset("RUST_LOG", || {
            assert_eq!(resolved_log_filter_from_env().to_string(), "harness=info");
        });
    }

    #[test]
    fn daemon_service_uses_persisted_log_level_when_env_is_unset() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("HARNESS_APP_GROUP_ID", None),
                ("XDG_DATA_HOME", None),
                ("RUST_LOG", None),
            ],
            || {
                daemon::state::persist_log_level(Some("debug")).expect("persist log level");
                let filter = resolved_log_filter_for_service(telemetry::RuntimeService::Daemon)
                    .expect("resolve daemon filter");
                assert_eq!(filter.to_string(), "harness=debug");
            },
        );
    }

    #[test]
    fn explicit_rust_log_overrides_persisted_daemon_log_level() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("HARNESS_APP_GROUP_ID", None),
                ("XDG_DATA_HOME", None),
                ("RUST_LOG", Some("harness=error")),
            ],
            || {
                daemon::state::persist_log_level(Some("debug")).expect("persist log level");
                let filter = resolved_log_filter_for_service(telemetry::RuntimeService::Daemon)
                    .expect("resolve daemon filter");
                assert_eq!(filter.to_string(), "harness=error");
            },
        );
    }

    #[test]
    fn non_daemon_service_ignores_persisted_daemon_log_level() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("HARNESS_APP_GROUP_ID", None),
                ("XDG_DATA_HOME", None),
                ("RUST_LOG", None),
            ],
            || {
                daemon::state::persist_log_level(Some("debug")).expect("persist log level");
                let filter = resolved_log_filter_for_service(telemetry::RuntimeService::Cli)
                    .expect("resolve cli filter");
                assert_eq!(filter.to_string(), "harness=info");
            },
        );
    }

    #[test]
    fn daemon_service_falls_back_to_info_when_persisted_config_is_malformed() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("HARNESS_APP_GROUP_ID", None),
                ("XDG_DATA_HOME", None),
                ("RUST_LOG", None),
            ],
            || {
                daemon::state::ensure_daemon_dirs().expect("ensure daemon dirs");
                fs_err::write(daemon::state::config_path(), "{not-json").expect("write config");

                let filter = resolved_log_filter_for_service(telemetry::RuntimeService::Daemon)
                    .expect("resolve daemon filter");
                assert_eq!(filter.to_string(), "harness=info");

                let event = daemon::state::read_recent_events(1)
                    .expect("read daemon events")
                    .pop()
                    .expect("warning event");
                assert_eq!(event.level, "warn");
                assert!(
                    event
                        .message
                        .contains("ignored persisted daemon log config")
                );
                assert!(event.message.contains("harness=info"));
            },
        );
    }

    #[test]
    fn daemon_service_falls_back_to_info_when_persisted_log_level_is_invalid() {
        let tmp = tempdir().expect("tempdir");
        temp_env::with_vars(
            [
                (
                    "HARNESS_DAEMON_DATA_HOME",
                    Some(tmp.path().to_str().expect("utf8 path")),
                ),
                ("HARNESS_APP_GROUP_ID", None),
                ("XDG_DATA_HOME", None),
                ("RUST_LOG", None),
            ],
            || {
                daemon::state::ensure_daemon_dirs().expect("ensure daemon dirs");
                fs_err::write(daemon::state::config_path(), r#"{"log_level":"verbose"}"#)
                    .expect("write config");

                let filter = resolved_log_filter_for_service(telemetry::RuntimeService::Daemon)
                    .expect("resolve daemon filter");
                assert_eq!(filter.to_string(), "harness=info");

                let event = daemon::state::read_recent_events(1)
                    .expect("read daemon events")
                    .pop()
                    .expect("warning event");
                assert_eq!(event.level, "warn");
                assert!(event.message.contains("invalid log level 'verbose'"));
            },
        );
    }

    #[test]
    fn bundled_launch_agent_does_not_pin_daemon_log_level() {
        const LAUNCH_AGENT: &str = include_str!(
            "../apps/harness-monitor-macos/Resources/LaunchAgents/io.harnessmonitor.daemon.plist"
        );

        assert!(!LAUNCH_AGENT.contains("<key>RUST_LOG</key>"));
    }
}
