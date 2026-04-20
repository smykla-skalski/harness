#![deny(unsafe_code)]
// harness-testkit: test fixture builders and helpers for the harness crate.
//
// Provides builder APIs that replace inline YAML/markdown/JSON strings
// in test code with readable, type-safe construction.

pub mod builders;
pub mod contracts;
pub mod env;
pub mod fake_binary;
pub mod fake_toolchain;

// Re-export everything from builders for convenience.
pub use builders::*;
pub use env::{init_git_repo_with_branches, init_git_repo_with_seed, with_isolated_harness_env};
pub use fake_toolchain::FakeToolchain;

/// Build an `assert_cmd::Command` for the harness binary.
///
/// # Panics
/// Panics if the binary cannot be found (not built).
#[must_use]
pub fn harness_cmd() -> assert_cmd::Command {
    assert_cmd::Command::cargo_bin("harness").expect("harness binary")
}
