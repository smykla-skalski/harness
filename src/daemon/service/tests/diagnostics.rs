use super::*;

#[test]
fn diagnostics_report_includes_workspace_and_recent_events() {
    let tmp = tempdir().expect("tempdir");
    let home = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("HOME", Some(home.path().to_str().expect("utf8 path"))),
        ],
        || {
            let manifest = DaemonManifest {
                version: "14.5.0".into(),
                pid: 42,
                endpoint: "http://127.0.0.1:9999".into(),
                started_at: "2026-03-28T12:00:00Z".into(),
                token_path: state::auth_token_path().display().to_string(),
                sandboxed: false,
                host_bridge: super::state::HostBridgeManifest::default(),
                revision: 0,
                updated_at: String::new(),
                binary_stamp: None,
            };
            state::write_manifest(&manifest).expect("manifest");
            state::append_event("info", "daemon booted").expect("append event");

            let report = diagnostics_report(None).expect("diagnostics");

            assert_eq!(
                report.manifest.expect("manifest").endpoint,
                manifest.endpoint
            );
            assert_eq!(report.health.expect("health").session_count, 0);
            assert!(report.workspace.events_path.ends_with("events.jsonl"));
            assert!(
                report
                    .recent_events
                    .iter()
                    .any(|event| event.message == "daemon booted"),
                "diagnostics should include the appended daemon event"
            );
        },
    );
}

/// Baseline: diagnostics_report returns running=false when no bridge is present.
#[test]
fn diagnostics_report_returns_default_bridge_when_no_bridge_running() {
    let tmp = tempdir().expect("tempdir");
    let home = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("HOME", Some(home.path().to_str().expect("utf8 path"))),
            ("HARNESS_DAEMON_DATA_HOME", None),
            ("HARNESS_APP_GROUP_ID", None),
        ],
        || {
            let manifest = DaemonManifest {
                version: "19.8.1".into(),
                pid: 42,
                endpoint: "http://127.0.0.1:9999".into(),
                started_at: "2026-04-12T10:00:00Z".into(),
                token_path: state::auth_token_path().display().to_string(),
                sandboxed: true,
                host_bridge: super::state::HostBridgeManifest::default(),
                revision: 0,
                updated_at: String::new(),
                binary_stamp: None,
            };
            state::write_manifest(&manifest).expect("manifest");

            let report = diagnostics_report(None).expect("diagnostics");
            let host_bridge = report.manifest.expect("manifest").host_bridge;

            assert!(
                !host_bridge.running,
                "diagnostics should return running=false when no bridge is running"
            );
        },
    );
}

/// Diagnostics should merge a live bridge probe so bridge state is always
/// current even when the file-watcher chain has stalled. This test is RED
/// before the fix lands.
#[test]
fn diagnostics_report_merges_live_bridge_state() {
    let tmp = tempdir().expect("tempdir");
    let home = tempdir().expect("tempdir");
    temp_env::with_vars(
        [
            (
                "XDG_DATA_HOME",
                Some(tmp.path().to_str().expect("utf8 path")),
            ),
            ("HOME", Some(home.path().to_str().expect("utf8 path"))),
            ("HARNESS_DAEMON_DATA_HOME", None),
            ("HARNESS_APP_GROUP_ID", None),
        ],
        || {
            // Write manifest with host_bridge.running = false (default)
            let manifest = DaemonManifest {
                version: "19.8.1".into(),
                pid: 42,
                endpoint: "http://127.0.0.1:9999".into(),
                started_at: "2026-04-12T10:00:00Z".into(),
                token_path: state::auth_token_path().display().to_string(),
                sandboxed: true,
                host_bridge: super::state::HostBridgeManifest::default(),
                revision: 0,
                updated_at: String::new(),
                binary_stamp: None,
            };
            state::write_manifest(&manifest).expect("manifest");

            // Write bridge.json with a codex capability to the daemon root
            state::ensure_daemon_dirs().expect("dirs");
            let bridge_state_path = bridge::bridge_state_path();
            let bridge_json = serde_json::json!({
                "socket_path": "/tmp/bridge.sock",
                "pid": std::process::id(),
                "started_at": "2026-04-12T10:00:00Z",
                "token_path": "/tmp/auth-token",
                "capabilities": {
                    "codex": {
                        "enabled": true,
                        "healthy": true,
                        "transport": "websocket",
                        "endpoint": "ws://127.0.0.1:4500",
                        "metadata": {}
                    }
                }
            });
            fs::write(
                &bridge_state_path,
                serde_json::to_string_pretty(&bridge_json).expect("json"),
            )
            .expect("write bridge state");

            // Acquire the bridge lock to simulate a running bridge process
            let _bridge_lock = bridge::acquire_bridge_lock_exclusive().expect("bridge lock");

            let report = diagnostics_report(None).expect("diagnostics");
            let host_bridge = report.manifest.expect("manifest").host_bridge;

            assert!(
                host_bridge.running,
                "diagnostics should return live running=true bridge state"
            );
            assert!(
                host_bridge.capabilities.contains_key("codex"),
                "diagnostics should include the codex capability from the live bridge"
            );
        },
    );
}
