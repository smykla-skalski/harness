use std::collections::BTreeMap;

use serde_json::{Value, json};
use tempfile::tempdir;

use crate::daemon::audit_events::{AuditEventRecordDraft, record_audit_event};
use crate::daemon::http::DaemonHttpAuthMode;
use crate::daemon::launchd::LaunchAgentStatus;
use crate::daemon::protocol::{http_paths, ws_methods};
use crate::daemon::remote::RemoteRole;
use crate::daemon::state::{
    self, DaemonAuditEvent, DaemonBinaryStamp, DaemonDiagnostics, DaemonManifest,
    HostBridgeCapabilityManifest, HostBridgeManifest,
};

use super::remote_viewer_support::{
    connect_remote_ws, get_http_json, register_remote_client, serve_http, ws_rpc,
};
use super::test_http_state_with_db;

const VIEWER_ID: &str = "viewer-diagnostics";
const ADMIN_ID: &str = "admin-diagnostics";

#[test]
fn remote_viewer_diagnostics_and_audit_reads_are_safe_over_http_and_websocket() {
    let sandbox = tempdir().expect("tempdir");
    harness_testkit::with_isolated_harness_env(sandbox.path(), || {
        tokio::runtime::Runtime::new()
            .expect("runtime")
            .block_on(run_remote_viewer_diagnostics_flow());
    });
}

async fn run_remote_viewer_diagnostics_flow() {
    let mut state = test_http_state_with_db();
    state.auth_mode = DaemonHttpAuthMode::Remote;
    state.remote_domain = Some("daemon.example.com".to_string());
    register_remote_client(&state, VIEWER_ID, RemoteRole::Viewer);
    register_remote_client(&state, ADMIN_ID, RemoteRole::Admin);
    seed_sensitive_diagnostics(&state).await;

    let (base_url, server) = serve_http(state).await;
    let client = reqwest::Client::new();

    let viewer_diagnostics =
        get_http_json(&client, &base_url, http_paths::DIAGNOSTICS, VIEWER_ID).await;
    assert_viewer_diagnostics(&viewer_diagnostics);
    let viewer_audit = get_http_json(&client, &base_url, http_paths::AUDIT_EVENTS, VIEWER_ID).await;
    assert_viewer_audit(&viewer_audit);

    let admin_diagnostics =
        get_http_json(&client, &base_url, http_paths::DIAGNOSTICS, ADMIN_ID).await;
    assert_full_diagnostics(&admin_diagnostics);
    let admin_audit = get_http_json(&client, &base_url, http_paths::AUDIT_EVENTS, ADMIN_ID).await;
    assert_full_audit(&admin_audit);

    let mut viewer_socket = connect_remote_ws(&base_url, VIEWER_ID).await;
    let viewer_ws_diagnostics = ws_rpc(
        &mut viewer_socket,
        "viewer-diagnostics",
        ws_methods::DIAGNOSTICS,
        Value::Null,
    )
    .await;
    assert_viewer_diagnostics(&viewer_ws_diagnostics["result"]);
    let viewer_ws_audit = ws_rpc(
        &mut viewer_socket,
        "viewer-audit",
        ws_methods::AUDIT_EVENTS,
        json!({}),
    )
    .await;
    assert_viewer_audit(&viewer_ws_audit["result"]);

    let mut admin_socket = connect_remote_ws(&base_url, ADMIN_ID).await;
    let admin_ws_diagnostics = ws_rpc(
        &mut admin_socket,
        "admin-diagnostics",
        ws_methods::DIAGNOSTICS,
        Value::Null,
    )
    .await;
    assert_full_diagnostics(&admin_ws_diagnostics["result"]);
    let admin_ws_audit = ws_rpc(
        &mut admin_socket,
        "admin-audit",
        ws_methods::AUDIT_EVENTS,
        json!({}),
    )
    .await;
    assert_full_audit(&admin_ws_audit["result"]);

    server.abort();
    let _ = server.await;
}

async fn seed_sensitive_diagnostics(state: &crate::daemon::http::DaemonHttpState) {
    state::write_manifest(&sensitive_manifest()).expect("write sensitive manifest");
    let db = state.db.get().expect("db slot").lock().expect("db lock");
    db.set_diagnostics_cache(
        "launch_agent",
        &serde_json::to_string(&sensitive_launch_agent()).expect("launch agent json"),
    )
    .expect("cache launch agent");
    db.set_diagnostics_cache(
        "workspace",
        &serde_json::to_string(&sensitive_workspace()).expect("workspace json"),
    )
    .expect("cache workspace");
    db.append_daemon_event(
        "2026-07-13T00:02:00Z",
        "warn",
        "diagnostics api_key=event-secret",
    )
    .expect("append daemon event");
    drop(db);

    record_audit_event(
        state.async_db.get(),
        AuditEventRecordDraft {
            source: "remote-test",
            category: "security",
            kind: "sensitive-event",
            severity: "warn",
            outcome: "failure",
            title: "Audit token=title-secret".to_string(),
            summary: "Audit password=summary-secret".to_string(),
            subject: Some("api_key=subject-secret".to_string()),
            actor: Some("token=actor-secret".to_string()),
            correlation_id: Some("safe-correlation".to_string()),
            action_key: Some("safe-action".to_string()),
            payload_json: Some(json!({
                "api_key": "payload-secret",
                "safe": "visible"
            })),
            legacy_message: Some("Bearer abcdefghijklmnop".to_string()),
            related_urls: vec!["https://user:password@example.com/private".to_string()],
        },
    )
    .await;
}

fn sensitive_manifest() -> DaemonManifest {
    DaemonManifest {
        version: "46.0.0".to_string(),
        pid: 42,
        endpoint: "https://daemon.example.com".to_string(),
        started_at: "2026-07-13T00:00:00Z".to_string(),
        token_path: "/private/auth-token".to_string(),
        sandboxed: false,
        host_bridge: HostBridgeManifest {
            running: true,
            socket_path: Some("/private/bridge.sock".to_string()),
            capabilities: BTreeMap::from([(
                "codex".to_string(),
                HostBridgeCapabilityManifest {
                    enabled: true,
                    healthy: true,
                    transport: "unix".to_string(),
                    endpoint: Some("/private/capability.sock".to_string()),
                    metadata: BTreeMap::from([(
                        "credential".to_string(),
                        "token=bridge-secret".to_string(),
                    )]),
                },
            )]),
        },
        revision: 1,
        updated_at: "2026-07-13T00:01:00Z".to_string(),
        binary_stamp: Some(DaemonBinaryStamp {
            helper_path: "/private/harness-helper".to_string(),
            device_identifier: 1,
            inode: 2,
            file_size: 3,
            modification_time_interval_since_1970: 4.0,
        }),
        ownership: Default::default(),
    }
}

fn sensitive_launch_agent() -> LaunchAgentStatus {
    LaunchAgentStatus {
        installed: true,
        loaded: true,
        label: "io.harness.daemon".to_string(),
        path: "/private/io.harness.daemon.plist".to_string(),
        domain_target: "gui/private-user".to_string(),
        service_target: "gui/private-user/io.harness.daemon".to_string(),
        state: Some("running".to_string()),
        pid: Some(42),
        last_exit_status: None,
        status_error: Some("password=launch-secret".to_string()),
    }
}

fn sensitive_workspace() -> DaemonDiagnostics {
    DaemonDiagnostics {
        daemon_root: "/private/daemon-root".to_string(),
        manifest_path: "/private/manifest.json".to_string(),
        auth_token_path: "/private/auth-token".to_string(),
        auth_token_present: true,
        events_path: "/private/events.jsonl".to_string(),
        database_path: "/private/harness.db".to_string(),
        database_size_bytes: 1024,
        last_event: Some(DaemonAuditEvent {
            recorded_at: "2026-07-13T00:02:00Z".to_string(),
            level: "warn".to_string(),
            message: "diagnostics token=workspace-secret".to_string(),
        }),
    }
}

fn assert_viewer_diagnostics(diagnostics: &Value) {
    let serialized = serde_json::to_string(diagnostics).expect("serialize diagnostics");
    for secret in [
        "/private/",
        "bridge-secret",
        "event-secret",
        "launch-secret",
        "workspace-secret",
        "private-user",
    ] {
        assert!(
            !serialized.contains(secret),
            "viewer diagnostics exposed {secret}: {serialized}"
        );
    }
    assert_eq!(diagnostics["manifest"]["token_path"], "[redacted]");
    assert_eq!(diagnostics["workspace"]["daemon_root"], "[redacted]");
    assert!(serialized.contains("[redacted]"));
}

fn assert_full_diagnostics(diagnostics: &Value) {
    assert_eq!(diagnostics["manifest"]["token_path"], "/private/auth-token");
    assert_eq!(
        diagnostics["workspace"]["daemon_root"],
        "/private/daemon-root"
    );
    assert_eq!(
        diagnostics["recent_events"][0]["message"],
        "diagnostics api_key=event-secret"
    );
}

fn assert_viewer_audit(audit: &Value) {
    let event = &audit["events"][0];
    let serialized = serde_json::to_string(event).expect("serialize audit event");
    for secret in [
        "title-secret",
        "summary-secret",
        "subject-secret",
        "actor-secret",
        "payload-secret",
        "abcdefghijklmnop",
        "user:password",
    ] {
        assert!(
            !serialized.contains(secret),
            "viewer audit exposed {secret}: {serialized}"
        );
    }
    assert!(event["payload_json"].is_null());
    assert_eq!(event["related_urls"], json!([]));
    assert_eq!(event["correlation_id"], "safe-correlation");
    assert_eq!(event["action_key"], "safe-action");
}

fn assert_full_audit(audit: &Value) {
    let event = &audit["events"][0];
    assert_eq!(event["payload_json"]["api_key"], "payload-secret");
    assert_eq!(
        event["related_urls"][0],
        "https://user:password@example.com/private"
    );
    assert_eq!(event["legacy_message"], "Bearer abcdefghijklmnop");
}
