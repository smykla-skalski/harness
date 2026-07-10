//! Local daemon for the Harness Monitor macOS app.
//!
//! When `HARNESS_SANDBOXED=1` (or `--sandboxed` on `harness daemon serve`),
//! all subprocess-spawning paths are gated: `launchd.rs` install/remove/restart
//! return `SANDBOX001`, `transport.rs::spawn_daemon` returns `SANDBOX001`, and
//! the Codex controller selects WebSocket transport instead of stdio.
//!
//! The daemon serves HTTP + WebSocket on loopback, reads/writes the app group
//! container, and dispatches sandboxed Codex runs through the unified host
//! bridge's Codex capability.
//!
//! Minimum codex version for WebSocket transport: `rust-v0.102.0+`.
//!
//! To test in sandbox mode locally:
//! ```text
//! HARNESS_SANDBOXED=1 cargo run --bin harness -- daemon serve --port 0
//! ```

use std::net::IpAddr;

use axum::http::Uri;

pub mod agent_acp;
pub mod agent_tui;
pub(crate) mod audit_events;
pub mod bridge;
pub mod client;
pub mod codex_controller;
pub mod codex_transport;
pub mod db;
pub mod discovery;
pub mod http;
pub mod index;
pub mod launchd;
pub mod ordering;
pub mod protocol;
pub mod remote;
pub mod remote_acme;
mod remote_acme_challenge;
mod remote_acme_cleanup;
pub mod remote_acme_dns;
mod remote_acme_dns_provider;
pub mod remote_acme_dns_runner;
mod remote_acme_issuer;
mod remote_acme_lease_guard;
mod remote_acme_live;
mod remote_acme_renewal;
pub mod remote_auth;
pub(crate) mod remote_certificate_identity;
pub(crate) mod remote_crypto;
pub mod remote_identity;
pub mod remote_pairing;
pub(crate) mod remote_redaction;
pub mod remote_tls;
pub mod service;
pub mod snapshot;
pub mod state;
pub(crate) mod task_board_managed_agents;
pub mod timeline;
pub mod transport;
pub mod voice;
pub mod watch;
pub mod websocket;

#[must_use]
pub(crate) fn is_loopback_host(host: &str) -> bool {
    let host = host.trim();
    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<IpAddr>()
            .is_ok_and(|address| address.is_loopback())
}

#[must_use]
pub(crate) fn is_local_websocket_endpoint(endpoint: &str) -> bool {
    let Ok(uri) = endpoint.trim().parse::<Uri>() else {
        return false;
    };
    let Some(scheme) = uri.scheme_str() else {
        return false;
    };
    if !matches!(scheme, "ws" | "wss") {
        return false;
    }
    let Some(host) = uri.host() else {
        return false;
    };
    is_loopback_host(host)
}
