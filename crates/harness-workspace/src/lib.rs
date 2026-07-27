//! Workspace layout, git access, sandbox resolution, and the shared command
//! execution context.
//!
//! These trees sit directly above `harness-kernel`: they own where harness
//! puts things on disk, how it reads and writes repositories, how it resolves
//! sandboxed project paths, and the `Execute`/`AppContext` handle command
//! dispatch runs through. Every other crate depends on this one directly
//! rather than re-including its sources with `#[path]`. `command_context` is
//! the one exception: `harness-daemon` still `#[path]`-includes it to keep
//! its own local `AppContext`/`Execute` nominal types, so that module alone
//! compiles more than once in the build graph.

#![deny(unsafe_code)]

pub mod command_context;
pub mod git;
pub mod sandbox;
pub mod workspace;
