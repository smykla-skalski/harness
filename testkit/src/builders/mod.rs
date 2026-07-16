// Builder types for constructing test fixture markdown and JSON payloads.
// Each builder produces the exact format expected by the harness parsers,
// replacing inline YAML/JSON strings scattered across test files.
//
// Test utilities intentionally panic on setup failures - callers are #[test]
// functions where an expect() failure is the correct way to surface problems.

mod frontmatter;
mod group;
mod suite;

#[cfg(test)]
mod tests;

pub use group::{
    GroupBuilder, MeshMetricGroupBuilder, default_group, write_group, write_meshmetric_group,
};
pub use suite::{SuiteBuilder, default_suite, default_universal_suite, write_suite};
