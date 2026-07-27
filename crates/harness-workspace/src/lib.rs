//! Workspace layout, git access, sandbox resolution, and the shared command
//! execution context.
//!
//! These trees sit directly above `harness-kernel`: they own where harness
//! puts things on disk, how it reads and writes repositories, how it resolves
//! sandboxed project paths, and the `Execute`/`AppContext` handle command
//! dispatch runs through. Every other crate depends on this one rather than
//! re-including its sources with `#[path]`, so a type defined here has
//! exactly one definition in the build graph.

#![deny(unsafe_code)]

pub mod command_context;
pub mod git;
pub mod sandbox;
pub mod workspace;
