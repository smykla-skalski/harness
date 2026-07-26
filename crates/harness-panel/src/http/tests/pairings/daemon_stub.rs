use std::sync::{Arc, Mutex};

use axum::Json;
use axum::Router;
use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use serde_json::Value;
use tokio::net::TcpListener;

/// The version the stub reports, distinct from the panel's own so a test cannot
/// pass by reading the wrong one back.
pub(super) const DAEMON_VERSION: &str = "52.0.0";

/// What the stub holds and what it saw.
#[derive(Debug, Default)]
pub(super) struct Daemon {
    /// The inventory the daemon reports, in the order it reports it.
    pub(super) pairings: Vec<StubPairing>,
    /// Every pairing id a revoke was asked about.
    pub(super) revoked: Vec<String>,
    pub(super) client_id: Option<String>,
    pub(super) authorization: Option<String>,
    /// Refuse the next revoke the way the daemon refuses one the caller may not
    /// see.
    pub(super) refuse_revoke: bool,
    /// Answer the way a daemon that does not serve this route does: the same
    /// status as a missing pairing, with nothing in the body.
    pub(super) unrouted_revoke: bool,
    /// Answer the way a daemon older than the field does, leaving the version
    /// out of an otherwise ordinary reply.
    pub(super) omit_version: bool,
}

#[derive(Debug)]
pub(super) struct StubPairing {
    minted_by: String,
    pub(super) body: Value,
}

pub(super) fn pairing(pairing_id: &str, state: &str) -> StubPairing {
    pairing_minted_by(pairing_id, state, "panel-1")
}

pub(super) fn pairing_minted_by(pairing_id: &str, state: &str, minted_by: &str) -> StubPairing {
    StubPairing {
        minted_by: minted_by.to_owned(),
        body: serde_json::json!({
            "pairing_id": pairing_id,
            "state": state,
            "role": "operator",
            "created_at": "2026-07-26T10:00:00Z",
            "expires_at": "2026-07-26T10:10:00Z",
        }),
    }
}

/// A claimed link, carrying the device it became.
pub(super) fn claimed(pairing_id: &str, device: &str) -> StubPairing {
    let mut entry = pairing(pairing_id, "active");
    entry.body["claimed_at"] = Value::String("2026-07-26T10:01:00Z".to_owned());
    entry.body["device"] = serde_json::json!({
        "client_id": format!("{pairing_id}-device"),
        "display_name": device,
        "platform": "macos",
        "last_seen_at": "2026-07-26T10:05:00Z",
    });
    entry
}

pub(super) async fn stub_daemon(daemon: Arc<Mutex<Daemon>>) -> String {
    let app = Router::new()
        .route("/v1/remote/pairings", get(list))
        .route("/v1/remote/pairings/{pairing_id}/revoke", post(revoke))
        .with_state(daemon);
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let address = listener.local_addr().expect("local address");
    tokio::spawn(async move {
        axum::serve(listener, app).await.ok();
    });
    format!("http://127.0.0.1:{}", address.port())
}

async fn list(State(daemon): State<Arc<Mutex<Daemon>>>, headers: HeaderMap) -> Response {
    let mut daemon = daemon.lock().expect("stub lock");
    daemon.client_id = header_value(&headers, "x-harness-remote-client-id");
    daemon.authorization = header_value(&headers, "authorization");
    let pairings = daemon
        .pairings
        .iter()
        .filter(|pairing| Some(pairing.minted_by.as_str()) == daemon.client_id.as_deref())
        .map(|pairing| pairing.body.clone())
        .collect::<Vec<_>>();
    let mut body = serde_json::json!({ "pairings": pairings });
    if !daemon.omit_version {
        body["daemon_version"] = Value::String(DAEMON_VERSION.to_owned());
    }
    Json(body).into_response()
}

async fn revoke(
    State(daemon): State<Arc<Mutex<Daemon>>>,
    Path(pairing_id): Path<String>,
    headers: HeaderMap,
) -> Response {
    let mut daemon = daemon.lock().expect("stub lock");
    if daemon.unrouted_revoke {
        return StatusCode::NOT_FOUND.into_response();
    }
    if daemon.refuse_revoke {
        return unavailable();
    }
    let client_id = header_value(&headers, "x-harness-remote-client-id");
    let owned = daemon.pairings.iter().any(|pairing| {
        pairing.body["pairing_id"] == pairing_id
            && Some(pairing.minted_by.as_str()) == client_id.as_deref()
    });
    if !owned {
        return unavailable();
    }
    daemon.revoked.push(pairing_id.clone());
    Json(serde_json::json!({
        "pairing_id": pairing_id,
        "outcome": "device_revoked",
        "revoked_at": "2026-07-26T11:00:00Z",
    }))
    .into_response()
}

fn unavailable() -> Response {
    (
        StatusCode::FORBIDDEN,
        Json(serde_json::json!({"error": {
            "code": "REMOTE_PAIRING_NOT_AVAILABLE",
            "message": "no pairing with that id is available to this client"
        }})),
    )
        .into_response()
}

fn header_value(headers: &HeaderMap, name: &str) -> Option<String> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .map(str::to_owned)
}
