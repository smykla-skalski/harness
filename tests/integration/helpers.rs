// Shared test helper utilities for integration tests.
// Delegates to harness-testkit builders for fixture construction.

#![allow(dead_code)]

use std::sync::Mutex;

// Re-export everything from the testkit so integration tests can use
// `helpers::write_suite`, `helpers::make_bash_payload`, etc. unchanged.
pub use harness_testkit::*;

/// Global lock for tests that modify the process environment via `with_env_vars`.
///
/// All integration test modules that set PATH (or other env vars) must acquire
/// this lock so that concurrent tests never observe a partially-modified
/// environment. Per-module locks are insufficient because Rust runs tests from
/// different modules on the same thread pool.
pub static ENV_LOCK: Mutex<()> = Mutex::new(());
