use super::*;

#[test]
fn daemon_serve_config_default_is_unsandboxed() {
    let config = DaemonServeConfig::default();
    assert!(!config.sandboxed);
    assert_eq!(config.codex_transport, CodexTransportKind::Stdio);
}

fn with_isolated_transport_env<F: FnOnce()>(ws_url: Option<&str>, f: F) {
    let tmp = tempfile::tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "HARNESS_DAEMON_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("HARNESS_APP_GROUP_ID", None),
            ("HARNESS_CODEX_WS_URL", ws_url),
            ("XDG_DATA_HOME", None),
        ],
        f,
    );
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
    assert_eq!(current_log_level(), crate::DEFAULT_LOG_LEVEL);
}
