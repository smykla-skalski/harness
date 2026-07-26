//! Generic infrastructure shared across product domains.

pub mod blocks;
pub mod environment;
pub mod exec;
// Deliberate public API facade, not scaffolding: `infra::io` stays a stable
// path for the callers that already name it. Code inside the workspace names
// `harness_kernel::io` directly, so do not add uses of `crate::infra::io` on
// the strength of this.
pub use harness_kernel::io;
pub mod persistence;
