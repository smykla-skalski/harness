//! Local daemon for the Harness Monitor macOS app.
//!
//! When `HARNESS_SANDBOXED=1` (or `--sandboxed` on `harness daemon serve`),
//! all subprocess-spawning paths are gated: `launchd.rs` install/remove/restart
//! return `SANDBOX001`, `transport.rs::spawn_daemon` returns `SANDBOX001`, and
//! the Codex controller selects WebSocket transport instead of stdio.
//!
//! The daemon serves HTTP + WebSocket on loopback, reads/writes the app group
//! container, and dispatches Codex runs to an externally-managed
//! `codex app-server` endpoint discovered via `codex-endpoint.json`.
//!
//! Minimum codex version for WebSocket transport: `rust-v0.102.0+`.
//!
//! To test in sandbox mode locally:
//! ```text
//! HARNESS_SANDBOXED=1 cargo run --bin harness -- daemon serve --port 0
//! ```

pub mod agent_tui;
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
pub mod service;
pub mod snapshot;
pub mod state;
pub mod timeline;
pub mod transport;
pub mod voice;
pub mod watch;
pub mod websocket;
