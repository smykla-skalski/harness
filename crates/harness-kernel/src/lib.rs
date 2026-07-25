//! The lowest layer of harness: error vocabulary and kernel domain primitives.
//!
//! Every other crate depends on this one rather than re-including its sources
//! with `#[path]`, so a type defined here has exactly one definition in the
//! build graph.

#![deny(unsafe_code)]

pub mod errors;
pub mod kernel;
pub mod redact;
