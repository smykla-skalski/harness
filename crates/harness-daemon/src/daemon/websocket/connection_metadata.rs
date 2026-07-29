use axum::http::HeaderMap;
use axum::http::header::{AUTHORIZATION, ORIGIN, USER_AGENT};
use tracing::field::display;

const HEADER_CLIENT_NAME: &str = "x-harness-client-name";
const HEADER_CLIENT_VERSION: &str = "x-harness-client-version";
const HEADER_CLIENT_BUNDLE_ID: &str = "x-harness-client-bundle-id";
const HEADER_CLIENT_PID: &str = "x-harness-client-pid";
const HEADER_CLIENT_LAUNCH_MODE: &str = "x-harness-client-launch-mode";
const HEADER_SEC_WEBSOCKET_PROTOCOL: &str = "sec-websocket-protocol";
const MISSING_METADATA: &str = "<missing>";
const HEADER_VALUE_LOG_LIMIT: usize = 160;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(super) struct WebSocketHandshakeMetadata {
    client_name: Option<String>,
    client_version: Option<String>,
    client_bundle_id: Option<String>,
    client_pid: Option<String>,
    client_launch_mode: Option<String>,
    user_agent: Option<String>,
    origin: Option<String>,
    websocket_protocol: Option<String>,
    auth_state: &'static str,
}

impl WebSocketHandshakeMetadata {
    pub(super) fn from_headers(headers: &HeaderMap) -> Self {
        Self {
            client_name: header_summary(headers, HEADER_CLIENT_NAME),
            client_version: header_summary(headers, HEADER_CLIENT_VERSION),
            client_bundle_id: header_summary(headers, HEADER_CLIENT_BUNDLE_ID),
            client_pid: header_summary(headers, HEADER_CLIENT_PID),
            client_launch_mode: header_summary(headers, HEADER_CLIENT_LAUNCH_MODE),
            user_agent: header_summary(headers, USER_AGENT.as_str()),
            origin: header_summary(headers, ORIGIN.as_str()),
            websocket_protocol: header_summary(headers, HEADER_SEC_WEBSOCKET_PROTOCOL),
            auth_state: auth_header_state(headers),
        }
    }

    pub(super) fn client_label(&self) -> String {
        let mut label = self
            .client_name
            .clone()
            .or_else(|| self.user_agent.clone())
            .unwrap_or_else(|| "unknown".to_string());
        if self.client_name.is_some()
            && let Some(version) = &self.client_version
        {
            label.push('/');
            label.push_str(version);
        }
        let mut details = Vec::new();
        if let Some(bundle_id) = &self.client_bundle_id {
            details.push(format!("bundle={bundle_id}"));
        }
        if let Some(pid) = &self.client_pid {
            details.push(format!("pid={pid}"));
        }
        if let Some(launch_mode) = &self.client_launch_mode {
            details.push(format!("launch={launch_mode}"));
        }
        if details.is_empty() {
            label
        } else {
            format!("{label} ({})", details.join("; "))
        }
    }

    pub(super) fn record_on_span(&self, span: &tracing::Span) {
        let client = self.client_label();
        span.record("client", display(&client));
        span.record(
            "client_name",
            display(self.client_name.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "client_version",
            display(self.client_version.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "client_bundle_id",
            display(self.client_bundle_id.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "client_pid",
            display(self.client_pid.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "client_launch_mode",
            display(
                self.client_launch_mode
                    .as_deref()
                    .unwrap_or(MISSING_METADATA),
            ),
        );
        span.record(
            "user_agent",
            display(self.user_agent.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "origin",
            display(self.origin.as_deref().unwrap_or(MISSING_METADATA)),
        );
        span.record(
            "websocket_protocol",
            display(
                self.websocket_protocol
                    .as_deref()
                    .unwrap_or(MISSING_METADATA),
            ),
        );
        span.record("auth_state", display(self.auth_state));
    }
}

fn header_summary(headers: &HeaderMap, name: &str) -> Option<String> {
    let raw = headers.get(name)?.to_str().ok()?.trim();
    if raw.is_empty() {
        return None;
    }
    let mut summary = raw.chars().take(HEADER_VALUE_LOG_LIMIT).collect::<String>();
    if raw.chars().count() > HEADER_VALUE_LOG_LIMIT {
        summary.push_str("...");
    }
    Some(summary)
}

fn auth_header_state(headers: &HeaderMap) -> &'static str {
    match headers.get(AUTHORIZATION) {
        None => "missing",
        Some(value) => match value.to_str() {
            Ok(raw) if raw.trim().starts_with("Bearer ") => "bearer-present",
            Ok(_) => "non-bearer",
            Err(_) => "invalid-utf8",
        },
    }
}

#[cfg(test)]
mod tests;
