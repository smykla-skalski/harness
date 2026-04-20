//! Sandbox-related helpers: security-scoped bookmark persistence and resolution.
//!
//! On macOS the Monitor app writes bookmarks here; the daemon reads them and
//! resolves them via `security-framework` when `HARNESS_SANDBOXED=1`.

pub mod bookmarks;
pub mod migration;
mod project_input;
pub mod resolver; // macOS-only; resolver.rs is gated by #![cfg(target_os = "macos")]

pub use project_input::{ProjectInputScope, resolve_project_input};
