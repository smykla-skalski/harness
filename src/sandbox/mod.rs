//! Sandbox-related helpers: security-scoped bookmark persistence and resolution.
//!
//! On macOS the Monitor app writes bookmarks here; the daemon reads them and
//! resolves them via `security-framework` when `HARNESS_SANDBOXED=1`.

pub mod bookmarks;

// pub mod resolver;   // added in Task 6 (macOS-only)
// pub mod migration;  // added in Task 8
