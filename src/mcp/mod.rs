//! Model Context Protocol (MCP) server integration.
//!
//! Exposes `harness mcp serve` which speaks the MCP JSON-RPC protocol over
//! stdio and drives the Harness Monitor macOS app through an accessibility
//! registry Unix socket, plus `CGEvent` and `screencapture` for input and
//! screenshot automation.
//!
//! The protocol and server loop are platform-agnostic. The Harness Monitor
//! integration and automation tools are only compiled on macOS.

pub mod protocol;
