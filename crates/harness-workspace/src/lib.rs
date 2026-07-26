//! Workspace layout, git access, and sandbox resolution.
//!
//! These three trees sit directly above `harness-kernel`: they own where
//! harness puts things on disk, how it reads and writes repositories, and how
//! it resolves sandboxed project paths. Every other crate depends on this one
//! rather than re-including its sources with `#[path]`, so a type defined here
//! has exactly one definition in the build graph.

#![deny(unsafe_code)]

pub mod git;
pub mod sandbox;
pub mod workspace;
