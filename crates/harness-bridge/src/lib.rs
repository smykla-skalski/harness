// Canonical unit tests run in the root package. Clippy still constructs a
// library test target for `--all-targets` even when Cargo marks it disabled.
#![cfg(not(test))]
#![deny(unsafe_code)]

pub mod agents;
pub mod app;
pub mod daemon;
pub mod errors;
pub mod feature_flags;
pub mod hooks;
pub mod infra;
pub mod kernel;
pub mod run;
pub mod session;
pub mod setup;
pub mod workspace;

#[cfg(target_os = "macos")]
pub mod startup_migration;
