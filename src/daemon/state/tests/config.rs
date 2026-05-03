use harness_testkit::with_isolated_harness_env;
use tempfile::tempdir;

use super::super::{
    DaemonRuntimeConfig, config_path, load_persisted_log_level, load_runtime_config,
    persist_log_level, read_recent_events,
};

#[test]
fn runtime_config_round_trips_persisted_log_level() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        persist_log_level(Some("debug")).expect("persist log level");

        assert_eq!(
            load_runtime_config().expect("load runtime config"),
            Some(DaemonRuntimeConfig {
                log_level: Some("debug".into()),
            })
        );
    });
}

#[test]
fn persisted_log_level_normalizes_case_and_whitespace() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        persist_log_level(Some(" Trace ")).expect("persist log level");

        assert_eq!(
            load_persisted_log_level().expect("load persisted log level"),
            Some("trace".into())
        );
    });
}

#[test]
fn config_path_lives_under_daemon_root() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        assert_eq!(
            config_path(),
            tmp.path()
                .join("harness")
                .join("daemon")
                .join("config.json")
        );
    });
}

#[test]
fn persisted_log_level_rejects_invalid_values() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        super::super::ensure_daemon_dirs().expect("ensure daemon dirs");
        fs_err::write(config_path(), r#"{"log_level":"verbose"}"#).expect("write config");

        let error = load_persisted_log_level()
            .expect_err("invalid persisted log level should fail validation");
        assert!(error.to_string().contains(
            "invalid log level 'verbose', expected one of: trace, debug, info, warn, error"
        ));
    });
}

#[test]
fn persist_log_level_replaces_malformed_runtime_config() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        super::super::ensure_daemon_dirs().expect("ensure daemon dirs");
        fs_err::write(config_path(), "{not-json").expect("write config");

        persist_log_level(Some("debug")).expect("persist repaired log level");

        assert_eq!(
            load_runtime_config().expect("load repaired runtime config"),
            Some(DaemonRuntimeConfig {
                log_level: Some("debug".into()),
            })
        );

        let event = read_recent_events(1)
            .expect("read daemon events")
            .pop()
            .expect("repair warning event");
        assert_eq!(event.level, "warn");
        assert!(
            event
                .message
                .contains("replacing invalid daemon runtime config")
        );
    });
}
