//! Local daemon for the Harness Monitor macOS app.
//!
//! When `HARNESS_SANDBOXED=1` (or `--sandboxed` on `harness-daemon serve`),
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
//! HARNESS_SANDBOXED=1 harness-daemon serve --port 0
//! ```

use std::{env, net::IpAddr};

use ::http::Uri;

/// Default app group used by Harness Monitor and local daemon discovery.
pub const HARNESS_MONITOR_APP_GROUP_ID: &str = "Q498EB36N4.io.harnessmonitor";

/// Return whether the current process was explicitly marked as sandboxed.
#[must_use]
pub fn sandboxed_from_env() -> bool {
    env::var("HARNESS_SANDBOXED").ok().is_some_and(|value| {
        matches!(
            value.trim(),
            "1" | "true" | "TRUE" | "yes" | "YES" | "on" | "ON"
        )
    })
}

pub mod agent_acp;
pub mod agent_tui;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod audit_events;
#[cfg(any(feature = "bridge-runtime", feature = "daemon-runtime"))]
pub mod bridge;
pub mod client;
#[cfg(feature = "daemon-runtime")]
pub mod codex_controller;
#[cfg(feature = "daemon-runtime")]
pub mod codex_transport;
#[cfg(feature = "daemon-runtime")]
pub mod db;
pub mod discovery;
#[cfg(feature = "daemon-runtime")]
pub mod http;
pub mod index;
pub mod launchd;
pub mod ordering;
pub mod protocol;
#[cfg(feature = "daemon-runtime")]
pub mod remote;
#[cfg(feature = "daemon-runtime")]
pub mod remote_acme;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_challenge;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_cleanup;
#[cfg(feature = "daemon-runtime")]
pub mod remote_acme_dns;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_dns_provider;
#[cfg(feature = "daemon-runtime")]
pub mod remote_acme_dns_runner;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_issuer;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_lease_guard;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_live;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_renewal;
#[cfg(feature = "daemon-runtime")]
pub mod remote_auth;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod remote_certificate_identity;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod remote_crypto;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod remote_diagnostics;
#[cfg(feature = "daemon-runtime")]
pub mod remote_identity;
#[cfg(feature = "daemon-runtime")]
pub mod remote_pairing;
#[cfg(feature = "daemon-runtime")]
mod remote_pairing_expiry_loop;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod remote_redaction;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod remote_request_audit;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod remote_task_board;
#[cfg(feature = "daemon-runtime")]
pub mod remote_tls;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod remote_viewer;
#[cfg(feature = "daemon-runtime")]
pub mod service;
#[cfg(feature = "daemon-runtime")]
pub mod snapshot;
pub mod state;
#[cfg(feature = "daemon-runtime")]
mod systemd_notify;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod task_board_managed_agents;
#[cfg(feature = "daemon-runtime")]
pub mod timeline;
#[cfg(feature = "daemon-runtime")]
pub mod transport;
#[cfg(feature = "daemon-runtime")]
pub mod voice;
#[cfg(feature = "daemon-runtime")]
pub mod watch;
#[cfg(feature = "daemon-runtime")]
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
