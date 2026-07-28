//! Generic infrastructure shared across product domains: process execution,
//! environment access, local persistence, and process/HTTP/build/clock
//! abstractions.
//!
//! Every other crate depends on this one rather than re-including its sources
//! with `#[path]`, so a type defined here has exactly one definition in the
//! build graph.

#![deny(unsafe_code)]

pub mod blocks;
pub mod environment;
pub mod exec;
// Deliberate public API facade, not scaffolding: `harness::infra::io` stays a
// stable path for the root crate's existing callers. Code inside the
// workspace names `harness_kernel::io` directly, so do not add uses of
// `harness_infra::io` on the strength of this.
pub use harness_kernel::io;
pub mod persistence;
