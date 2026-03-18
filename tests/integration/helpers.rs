// Shared test helper utilities for integration tests.
// Delegates to harness-testkit builders for fixture construction.

#![allow(dead_code)]

use std::sync::Mutex;

use harness::cli::{self, Command};
use harness::errors::CliError;

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

pub fn run_command(command: Command) -> Result<i32, CliError> {
    cli::dispatch(&command)
}

pub trait CommandExt {
    fn execute(self) -> Result<i32, CliError>;
}

impl CommandExt for Command {
    fn execute(self) -> Result<i32, CliError> {
        run_command(self)
    }
}
