//! Agent Client Protocol (ACP) runtime support.
//!
//! Paradigm shift: harness is moving from TUI-wrapper (spawn a binary in a PTY,
//! scrape its transcript) to agent-host (speak ACP JSON-RPC over stdio and
//! actively service `fs/*`, `terminal/*`, `session/request_permission`). This
//! module is the second leg of that move; `RuntimeKind` (Chunk 2) is the first.
//!
//! Chunk 1 lands the static catalog and the Copilot descriptor. The connection,
//! supervision, permission, and event-materialiser layers arrive in later
//! chunks.
pub mod catalog;
pub mod client;
pub mod permission;
