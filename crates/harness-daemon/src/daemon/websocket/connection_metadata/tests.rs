use axum::http::HeaderMap;
use axum::http::header::{AUTHORIZATION, ORIGIN, USER_AGENT};

use super::*;

#[test]
fn handshake_metadata_extracts_monitor_client_headers() {
    let mut headers = HeaderMap::new();
    headers.insert(
        USER_AGENT,
        "HarnessMonitor/30.32.0".parse().expect("user agent"),
    );
    headers.insert(
        HEADER_CLIENT_NAME,
        "harness-monitor".parse().expect("client name"),
    );
    headers.insert(
        HEADER_CLIENT_VERSION,
        "30.32.0".parse().expect("client version"),
    );
    headers.insert(
        HEADER_CLIENT_BUNDLE_ID,
        "io.harnessmonitor.app".parse().expect("bundle id"),
    );
    headers.insert(HEADER_CLIENT_PID, "70891".parse().expect("client pid"));
    headers.insert(
        HEADER_CLIENT_LAUNCH_MODE,
        "live".parse().expect("launch mode"),
    );
    headers.insert(ORIGIN, "app://harness-monitor".parse().expect("origin"));
    headers.insert(
        HEADER_SEC_WEBSOCKET_PROTOCOL,
        "jsonrpc".parse().expect("websocket protocol"),
    );
    headers.insert(AUTHORIZATION, "Bearer token".parse().expect("auth header"));

    let metadata = WebSocketHandshakeMetadata::from_headers(&headers);
    assert_eq!(metadata.client_name.as_deref(), Some("harness-monitor"));
    assert_eq!(metadata.client_version.as_deref(), Some("30.32.0"));
    assert_eq!(
        metadata.client_bundle_id.as_deref(),
        Some("io.harnessmonitor.app")
    );
    assert_eq!(metadata.client_pid.as_deref(), Some("70891"));
    assert_eq!(metadata.client_launch_mode.as_deref(), Some("live"));
    assert_eq!(
        metadata.user_agent.as_deref(),
        Some("HarnessMonitor/30.32.0")
    );
    assert_eq!(metadata.origin.as_deref(), Some("app://harness-monitor"));
    assert_eq!(metadata.websocket_protocol.as_deref(), Some("jsonrpc"));
    assert_eq!(metadata.auth_state, "bearer-present");
    assert_eq!(
        metadata.client_label(),
        "harness-monitor/30.32.0 (bundle=io.harnessmonitor.app; pid=70891; launch=live)"
    );
}

#[test]
fn handshake_metadata_tracks_auth_state_without_leaking_tokens() {
    let missing = WebSocketHandshakeMetadata::from_headers(&HeaderMap::new());
    assert_eq!(missing.auth_state, "missing");

    let mut non_bearer_headers = HeaderMap::new();
    non_bearer_headers.insert(AUTHORIZATION, "Basic abc".parse().expect("auth header"));
    let non_bearer = WebSocketHandshakeMetadata::from_headers(&non_bearer_headers);
    assert_eq!(non_bearer.auth_state, "non-bearer");
    assert_eq!(non_bearer.client_label(), "unknown");
}
