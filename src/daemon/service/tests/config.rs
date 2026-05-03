use super::*;

static LOG_FILTER_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
static TEST_LOG_FILTER_LAYER: OnceLock<
    tracing_subscriber::reload::Layer<tracing_subscriber::EnvFilter, tracing_subscriber::Registry>,
> = OnceLock::new();

#[test]
fn daemon_serve_config_default_is_unsandboxed() {
    let config = DaemonServeConfig::default();
    assert!(!config.sandboxed);
    assert_eq!(config.codex_transport, CodexTransportKind::Stdio);
}

fn with_isolated_transport_env<F: FnOnce()>(ws_url: Option<&str>, f: F) {
    let tmp = tempfile::tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        temp_env::with_var("HARNESS_CODEX_WS_URL", ws_url, f)
    });
}

fn ensure_test_log_filter_handle() {
    if crate::log_filter_handle().is_some() {
        return;
    }

    let (layer, handle) = tracing_subscriber::reload::Layer::new(
        tracing_subscriber::EnvFilter::new(crate::DEFAULT_LOG_FILTER_DIRECTIVE),
    );
    TEST_LOG_FILTER_LAYER
        .set(layer)
        .expect("test log filter layer already initialized");
    crate::set_log_filter_handle(handle);
}

#[test]
fn codex_transport_from_env_defaults_to_stdio_when_unsandboxed() {
    with_isolated_transport_env(None, || {
        assert_eq!(codex_transport_from_env(false), CodexTransportKind::Stdio);
    });
}

#[test]
fn codex_transport_from_env_defaults_to_websocket_when_sandboxed() {
    with_isolated_transport_env(None, || {
        assert_eq!(
            codex_transport_from_env(true),
            CodexTransportKind::WebSocket {
                endpoint: super::codex_transport::DEFAULT_CODEX_WS_ENDPOINT.to_string(),
            }
        );
    });
}

#[test]
fn codex_transport_from_env_overrides_via_environment() {
    with_isolated_transport_env(Some("ws://10.0.0.5:7000"), || {
        assert_eq!(
            codex_transport_from_env(false),
            CodexTransportKind::WebSocket {
                endpoint: "ws://10.0.0.5:7000".to_string(),
            }
        );
    });
}

#[test]
fn serve_rejects_non_loopback_bind_host() {
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        let runtime = tokio::runtime::Runtime::new().expect("runtime");
        let result = runtime.block_on(async {
            tokio::time::timeout(
                std::time::Duration::from_millis(200),
                serve(DaemonServeConfig {
                    host: "0.0.0.0".into(),
                    ..DaemonServeConfig::default()
                }),
            )
            .await
        });
        match result {
            Ok(Err(error)) => assert!(error.to_string().contains("loopback")),
            Ok(Ok(())) => panic!("serve should reject non-loopback hosts"),
            Err(_) => panic!("serve should fail before starting"),
        }
    });
}

#[test]
fn sandboxed_from_env_detects_truthy_values() {
    for value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] {
        temp_env::with_var("HARNESS_SANDBOXED", Some(value), || {
            assert!(
                sandboxed_from_env(),
                "expected HARNESS_SANDBOXED={value} to enable sandbox mode"
            );
        });
    }
}

#[test]
fn sandboxed_from_env_rejects_falsy_and_unset_values() {
    for value in ["0", "false", "no", "off", "", "anything-else"] {
        temp_env::with_var("HARNESS_SANDBOXED", Some(value), || {
            assert!(
                !sandboxed_from_env(),
                "expected HARNESS_SANDBOXED={value} to leave sandbox mode disabled"
            );
        });
    }
    temp_env::with_var("HARNESS_SANDBOXED", Option::<&str>::None, || {
        assert!(!sandboxed_from_env());
    });
}

#[test]
fn current_log_level_defaults_to_info_when_handle_is_unavailable() {
    let _guard = LOG_FILTER_TEST_LOCK.lock().expect("log filter test lock");
    ensure_test_log_filter_handle();
    super::status::validate_and_reload_filter(crate::DEFAULT_LOG_LEVEL).expect("reset log filter");
    assert_eq!(current_log_level(), crate::DEFAULT_LOG_LEVEL);
}

#[test]
fn set_log_level_repairs_malformed_runtime_config() {
    let _guard = LOG_FILTER_TEST_LOCK.lock().expect("log filter test lock");
    let tmp = tempdir().expect("tempdir");
    with_isolated_harness_env(tmp.path(), || {
        ensure_test_log_filter_handle();
        super::status::validate_and_reload_filter(crate::DEFAULT_LOG_LEVEL)
            .expect("reset log filter");
        state::ensure_daemon_dirs().expect("ensure daemon dirs");
        fs::write(state::config_path(), "{not-json").expect("write malformed config");

        let (sender, _) = broadcast::channel(8);
        let response = set_log_level(
            &SetLogLevelRequest {
                level: "debug".into(),
            },
            &sender,
        )
        .expect("repair malformed config via set_log_level");

        assert_eq!(response.level, "debug");
        assert_eq!(response.filter, "harness=debug");
        assert_eq!(
            state::load_runtime_config().expect("load repaired runtime config"),
            Some(state::DaemonRuntimeConfig {
                log_level: Some("debug".into()),
            })
        );

        let events = state::read_recent_events(2).expect("read daemon events");
        assert!(events.iter().any(|event| {
            event.level == "warn"
                && event
                    .message
                    .contains("replacing invalid daemon runtime config")
        }));
        assert!(
            events.iter().any(|event| event.level == "info"
                && event.message.contains("log level changed to debug"))
        );
    });
}
