use super::{
    BRIDGE_CAPABILITY_CODEX, BTreeMap, BTreeSet, BridgeCapability, BridgeConfigArgs,
    BridgeReconfigureSpec, BridgeResponse, BridgeState, HostBridgeCapabilityManifest, PathBuf,
    PersistedBridgeConfig, StdUnixListener, bridge_response_error, cleanup_legacy_bridge_artifacts,
    compiled_capabilities, fs, merged_persisted_config, process_id, read_bridge_config,
    read_bridge_state, state, tempdir, with_temp_daemon_root, write_bridge_config,
    write_bridge_state,
};

#[test]
fn cleanup_legacy_bridge_artifacts_keeps_external_socket_path() {
    with_temp_daemon_root(|| {
        state::ensure_daemon_dirs().expect("dirs");
        let outside = tempdir().expect("tempdir");
        let victim = outside.path().join("victim.sock");
        fs::write(&victim, "sensitive").expect("write victim");
        fs::write(
            state::daemon_root().join("agent-tui-bridge.json"),
            serde_json::to_string(&serde_json::json!({
                "socket_path": victim.display().to_string(),
            }))
            .expect("serialize state"),
        )
        .expect("write legacy state");

        cleanup_legacy_bridge_artifacts();

        assert!(victim.exists(), "cleanup removed external file");
    });
}

#[test]
fn cleanup_legacy_bridge_artifacts_removes_owned_legacy_socket() {
    with_temp_daemon_root(|| {
        state::ensure_daemon_dirs().expect("dirs");
        let socket_path = state::daemon_root().join("legacy-agent-tui.sock");
        let _listener = StdUnixListener::bind(&socket_path).expect("bind legacy agent tui socket");
        fs::write(
            state::daemon_root().join("agent-tui-bridge.json"),
            serde_json::to_string(&serde_json::json!({
                "socket_path": socket_path.display().to_string(),
            }))
            .expect("serialize state"),
        )
        .expect("write legacy state");

        cleanup_legacy_bridge_artifacts();

        assert!(!socket_path.exists(), "cleanup kept daemon-owned socket");
    });
}

#[test]
fn compiled_capabilities_default_to_all_known_entries() {
    let capabilities = compiled_capabilities();
    assert!(capabilities.contains(&BridgeCapability::Codex));
    assert!(capabilities.contains(&BridgeCapability::AgentTui));
}

#[test]
fn config_defaults_to_all_capabilities() {
    let merged = merged_persisted_config(
        &BridgeConfigArgs {
            capabilities: Vec::new(),
            socket_path: None,
            codex_port: None,
            codex_path: None,
        },
        None,
    );
    assert_eq!(merged.capabilities_set(), compiled_capabilities());
}

#[test]
fn config_honors_explicit_capability_subset_and_persisted_defaults() {
    let merged = merged_persisted_config(
        &BridgeConfigArgs {
            capabilities: vec![BridgeCapability::AgentTui],
            socket_path: None,
            codex_port: None,
            codex_path: None,
        },
        Some(PersistedBridgeConfig {
            capabilities: vec![BridgeCapability::Codex],
            socket_path: Some(PathBuf::from("/tmp/custom.sock")),
            codex_port: Some(14567),
            codex_path: Some(PathBuf::from("/tmp/mock-codex")),
        }),
    );
    assert_eq!(
        merged.capabilities_set(),
        BTreeSet::from([BridgeCapability::AgentTui])
    );
    assert_eq!(merged.socket_path, Some(PathBuf::from("/tmp/custom.sock")));
    assert_eq!(merged.codex_port, Some(14567));
    assert_eq!(merged.codex_path, Some(PathBuf::from("/tmp/mock-codex")));
}

#[test]
fn read_bridge_state_returns_none_when_missing() {
    with_temp_daemon_root(|| {
        assert!(read_bridge_state().expect("read").is_none());
    });
}

#[test]
fn write_then_read_roundtrips_bridge_state() {
    with_temp_daemon_root(|| {
        let state = BridgeState {
            socket_path: "/tmp/bridge.sock".to_string(),
            pid: process_id(),
            started_at: "2026-04-11T12:00:00Z".to_string(),
            token_path: "/tmp/auth-token".to_string(),
            capabilities: BTreeMap::from([(
                BRIDGE_CAPABILITY_CODEX.to_string(),
                HostBridgeCapabilityManifest {
                    enabled: true,
                    healthy: true,
                    transport: "websocket".to_string(),
                    endpoint: Some("ws://127.0.0.1:4500".to_string()),
                    metadata: BTreeMap::from([("port".to_string(), "4500".to_string())]),
                },
            )]),
        };
        write_bridge_state(&state).expect("write");
        let loaded = read_bridge_state().expect("read").expect("state");
        assert_eq!(loaded, state);
    });
}

#[test]
fn write_then_read_roundtrips_bridge_config() {
    with_temp_daemon_root(|| {
        let config = PersistedBridgeConfig {
            capabilities: vec![BridgeCapability::AgentTui],
            socket_path: Some(PathBuf::from("/tmp/bridge.sock")),
            codex_port: Some(14500),
            codex_path: Some(PathBuf::from("/tmp/mock-codex")),
        };
        write_bridge_config(&config).expect("write");
        let loaded = read_bridge_config().expect("read").expect("config");
        assert_eq!(loaded, config);
    });
}

#[test]
fn reconfigure_spec_rejects_duplicate_and_conflicting_capabilities() {
    let duplicate = BridgeReconfigureSpec {
        enable: vec![BridgeCapability::Codex, BridgeCapability::Codex],
        disable: Vec::new(),
        force: false,
    };
    assert_eq!(
        duplicate.validate().expect_err("duplicate enable").code(),
        "WORKFLOW_PARSE"
    );

    let conflicting = BridgeReconfigureSpec {
        enable: vec![BridgeCapability::Codex],
        disable: vec![BridgeCapability::Codex],
        force: false,
    };
    assert_eq!(
        conflicting.validate().expect_err("conflict").code(),
        "WORKFLOW_PARSE"
    );
}

#[test]
fn reconfigure_names_reject_unknown_capability() {
    let error = BridgeReconfigureSpec::from_names(
        &[String::from("codex")],
        &[String::from("unknown")],
        false,
    )
    .expect_err("unknown capability");
    assert_eq!(error.code(), "WORKFLOW_PARSE");
}

#[test]
fn bridge_response_error_preserves_session_agent_conflict_code() {
    let error = bridge_response_error(BridgeResponse {
        ok: false,
        code: Some("KSRCLI092".to_string()),
        message: Some(
            "session agent conflict: agent-tui capability has 1 active session(s); rerun with --force to stop them first"
                .to_string(),
        ),
        details: None,
        payload: None,
    });

    assert_eq!(error.code(), "KSRCLI092");
    assert!(
        error
            .message()
            .contains("agent-tui capability has 1 active session(s)")
    );
}
