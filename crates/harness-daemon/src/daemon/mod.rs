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

use std::env;
#[cfg(feature = "daemon-runtime")]
use std::net::IpAddr;

#[cfg(feature = "daemon-runtime")]
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
#[cfg(feature = "daemon-runtime")]
pub mod cli_support;
#[cfg(feature = "daemon-runtime")]
pub mod codex_controller;
#[cfg(feature = "daemon-runtime")]
pub mod codex_transport;
#[cfg(feature = "daemon-runtime")]
pub mod db;
#[cfg(feature = "daemon-runtime")]
pub mod db_handle;
#[cfg(feature = "daemon-runtime")]
mod db_open;
// `discovery` moved natively into `harness-daemon-discovery`, which
// `harness-bridge` now depends on directly instead of duplicating this
// module's source through a `#[path]` include. A thin re-export over the
// real dependency keeps every existing `crate::daemon::discovery::*` call
// site unchanged.
pub mod discovery {
    pub use harness_daemon_discovery::*;
}
#[cfg(feature = "daemon-runtime")]
pub mod http;
// Filesystem-scanning session/project discovery lives in `session::index`;
// re-exported under the old name so the daemon's own DB-import and
// mutation-fallback call sites across this subtree keep resolving
// `crate::daemon::index::*` without touching every one of them.
pub use crate::session::index;
// `launchd` moved natively into `harness-daemon-launchd`. A thin re-export
// over the real dependency keeps every existing `crate::daemon::launchd::*`
// call site unchanged.
pub mod launchd {
    pub use harness_daemon_launchd::*;
}
pub mod ordering;
#[cfg(feature = "daemon-runtime")]
mod policy_runtime_store;
pub mod protocol;
#[cfg(feature = "daemon-runtime")]
mod pull_request_action_store;
#[cfg(feature = "daemon-runtime")]
pub mod remote;
#[cfg(feature = "daemon-runtime")]
pub mod remote_acme;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_challenge;
#[cfg(feature = "daemon-runtime")]
pub mod remote_acme_cleanup;
#[cfg(feature = "daemon-runtime")]
pub mod remote_acme_issuer;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_lease_guard;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_live;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_queries;
#[cfg(feature = "daemon-runtime")]
mod remote_acme_renewal;
#[cfg(feature = "daemon-runtime")]
pub mod remote_auth;
#[cfg(feature = "daemon-runtime")]
pub mod remote_certificate_identity;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod remote_crypto;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod remote_diagnostics;
#[cfg(feature = "daemon-runtime")]
pub mod remote_identity;
#[cfg(feature = "daemon-runtime")]
mod remote_identity_queries;
#[cfg(feature = "daemon-runtime")]
pub mod remote_pairing;
#[cfg(feature = "daemon-runtime")]
mod remote_pairing_expiry_loop;
#[cfg(feature = "daemon-runtime")]
mod remote_pairing_queries;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod remote_request_audit;
#[cfg(feature = "daemon-runtime")]
pub mod remote_tls;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod remote_viewer;
#[cfg(feature = "daemon-runtime")]
#[cfg(feature = "daemon-runtime")]
mod reviews_store;
#[cfg(feature = "daemon-runtime")]
pub mod serve;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod server_state;
#[cfg(feature = "daemon-runtime")]
pub mod service;
// `state` moved natively into `harness-daemon-state` (bridge-shared
// primitives split further into `harness-daemon-root`), which now owns and
// runs its own unit tests directly. A thin re-export over the real
// dependency, rather than a `#[path]` mirror, keeps every existing
// `crate::daemon::state::*` call site unchanged while letting a state-only
// edit skip recompiling this crate entirely.
pub mod state {
    pub use harness_daemon_state::*;
}
#[cfg(feature = "daemon-runtime")]
pub(crate) mod automation_kill_switch;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod task_board_managed_agents;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod task_board_read_only_coordinator;
#[cfg(all(feature = "daemon-runtime", test))]
pub(in crate::daemon) mod task_board_read_only_coordinator_tests;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod task_board_read_only_runtime;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod task_board_remote_result_import;
#[cfg(feature = "daemon-runtime")]
pub(crate) mod task_board_remote_transport;
#[cfg(test)]
pub(crate) mod test_liveness;
// Session-timeline construction lives in `harness_timeline`; re-exported
// under the old name so the daemon's own `db`, `service`, and `http` call
// sites keep resolving `crate::daemon::timeline::*` without touching every
// one of them.
#[cfg(feature = "daemon-runtime")]
pub use crate::timeline;
#[cfg(feature = "daemon-runtime")]
pub mod voice;
#[cfg(feature = "daemon-runtime")]
pub mod watch;
#[cfg(feature = "daemon-runtime")]
pub mod websocket;

#[must_use]
#[cfg(feature = "daemon-runtime")]
pub(crate) fn is_loopback_host(host: &str) -> bool {
    let host = host.trim();
    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<IpAddr>()
            .is_ok_and(|address| address.is_loopback())
}

#[must_use]
#[cfg(feature = "daemon-runtime")]
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
