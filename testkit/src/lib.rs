#![deny(unsafe_code)]
// harness-testkit: test fixture builders and helpers for the harness crate.
//
// Provides builder APIs that replace inline YAML/markdown/JSON strings
// in test code with readable, type-safe construction.

pub mod builders;
pub mod env;
pub mod fake_binary;
pub mod fake_toolchain;

// Re-export everything from builders for convenience.
pub use builders::*;
pub use env::{
    git_branches_matching, git_head_sha, init_git_repo_with_branches, init_git_repo_with_seed,
    with_isolated_harness_env,
};
pub use fake_toolchain::FakeToolchain;
