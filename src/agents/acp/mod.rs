//! Agent Client Protocol (ACP) runtime support.
//!
//! Paradigm shift: harness is moving from TUI-wrapper (spawn a binary in a PTY,
//! scrape its transcript) to agent-host (speak ACP JSON-RPC over stdio and
//! actively service `fs/*`, `terminal/*`, `session/request_permission`). This
//! module is the second leg of that move; `RuntimeKind` (Chunk 2) is the first.
//!
//! Architecture:
//!
//! - `catalog/` - static agent descriptors (Copilot, etc.) and config-file loader
//! - `client/` - ACP `Client` impl handling fs/terminal/permission requests
//! - `permission` - permission mode enum (`Stdin`, `Recording`, `DaemonBridge`)
//! - `supervision/` - session lifecycle, watchdog, process-group reaping
//! - `ring` - per-session bounded ring buffer with fold-flush thresholds
//! - `connection` - receive loop on dedicated tokio task, NDJSON parsing
//! - `events` - flush-boundary materialiser (`SessionUpdate` -> `ConversationEvent`)
//! - `throughput_bench` - CI-gated performance benchmark

pub mod batcher;
pub mod catalog;
pub mod client;
pub mod connection;
pub mod events;
pub mod permission;
pub mod probe;
pub mod ring;
pub mod supervision;
pub mod throughput_bench;
