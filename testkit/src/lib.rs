// harness-testkit: test fixture builders and helpers for the harness crate.
//
// Provides builder APIs that replace inline YAML/markdown/JSON strings
// in test code with readable, type-safe construction.

use std::env;

pub mod builders;
pub mod fake_binary;
pub mod fake_toolchain;

// Re-export everything from builders for convenience.
pub use builders::*;
pub use fake_toolchain::FakeToolchain;

/// Build an `assert_cmd::Command` for the harness binary.
///
/// # Panics
/// Panics if the binary cannot be found (not built).
#[must_use]
pub fn harness_cmd() -> assert_cmd::Command {
    assert_cmd::Command::cargo_bin("harness").expect("harness binary")
}

/// Set environment variables, run a closure, then restore previous values.
///
/// Pass `Some(value)` to set a variable, `None` to unset it.
///
/// # Safety
/// Mutating environment variables is inherently unsafe in a multi-threaded
/// context. Callers must ensure no other threads read the same variables
/// concurrently (e.g. by combining env-dependent tests into a single
/// `#[test]` function).
pub unsafe fn with_env_vars(vars: &[(&str, Option<&str>)], f: impl FnOnce()) {
    let saved: Vec<(&str, Option<String>)> = vars
        .iter()
        .map(|(name, _)| (*name, env::var(name).ok()))
        .collect();
    for (name, value) in vars {
        match value {
            Some(v) => unsafe { env::set_var(name, v) },
            None => unsafe { env::remove_var(name) },
        }
    }
    f();
    for (name, prev) in saved {
        match prev {
            Some(v) => unsafe { env::set_var(name, v) },
            None => unsafe { env::remove_var(name) },
        }
    }
}
